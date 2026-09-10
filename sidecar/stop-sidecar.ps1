<#
  Stop the semantic sidecar SERVICE, and verify that it is gone.

  WHY IT EXISTS, 2026-09-10. Ruling R1 of design\PLAN-brain-v2-2026-09-09.md says the sidecar does
  not run in the nightly GPU window. ops\sidecar-watchdog.ps1 honours half of that: it will not START
  the service between 21:30 and 06:30. Nothing honoured the other half. The watchdog's first daytime
  run restores the service at 06:30, it stays resident all day, and at 21:30
  graph\pipeline\nightly.ps1's Test-SidecarUp is true for it, so `serve` records BLIND and throws
  before resolve - every night, with the watchdog working exactly as designed. The nightly already
  stops a leftover llama-server for the same reason; this is the sidecar's equivalent, and it lives
  in sidecar\ because a module owns how it starts AND how it stops.

  IDENTIFIED BY SHAPE, NEVER BY TIMING OR BY NAME. Every interpreter on this box is python.exe. The
  service is a process whose command line runs `uvicorn app:app` AND either
    * its executable lives under this module's .venv, or
    * its PARENT is such a process.
  The second clause is the trap. The venv's python.exe is a redirector: it spawns the base
  interpreter named in pyvenv.cfg as a CHILD, and the child is the process that owns the socket. A
  match on the executable path alone finds the parent, kills it, and leaves the listener running.
  The nightly's own sweep also runs under sidecar\.venv and must never match; it carries no uvicorn.

  THE PORT IS A CROSS-CHECK, NOT THE KEY. A listener on the port that is not the service is REPORTED
  and never killed: this module does not own whatever that is.

  Exit 0 = no service process remains and the port is free (including "there was nothing to stop").
  Exit 1 = the service is still up after the wait, or the port is held by something else.
  Exit 3 = could not evaluate (the process table could not be read).

  SCOPE OF A CLEAN REPORT: SOUND for a service launched the way sidecar\start-sidecar.ps1 launches
  it, UNSOUND for any other spelling. A sidecar started by hand with a different ASGI target or from
  a different interpreter does not match, and the port cross-check is what makes that visible rather
  than silent.
#>
[CmdletBinding()]
param(
  [switch]$SelfTest,
  [switch]$ListOnly,
  [int]$Port = 8077,
  [int]$WaitSec = 30,
  # WHICH CHECKOUT'S SERVICE. Empty means this file's own sidecar\, which is what the nightly wants.
  # Named explicitly from a worktree, whose copy of this file would otherwise look for a service under
  # a .venv that only the main checkout has - and report "nothing to stop" about a service it never
  # looked for. Defaulted below, not here: [CmdletBinding()] empties $PSScriptRoot in param defaults.
  [string]$ServiceDir = ''
)

$ErrorActionPreference = 'Stop'
$SidecarDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $SidecarDir
. (Join-Path $RepoRoot 'lib\guard-contract.ps1')
$MatchDir = if ($ServiceDir) { $ServiceDir.TrimEnd('\') } else { $SidecarDir }

function Select-SidecarServiceProcess {
  <# The rows that ARE the service. Pure over its arguments: the fixtures below touch no process.
     Emits matching rows to the pipeline (never a comma-returned array), so a caller assigns and
     then filters out nulls. #>
  param([object[]]$Rows, [string]$SidecarDir)
  $venvRoot = (Join-Path $SidecarDir '.venv').TrimEnd('\') + '\'
  $byPid = @{}
  foreach ($r in @($Rows)) {
    if ($null -ne $r) { $byPid[[int]$r.ProcessId] = $r }
  }
  foreach ($r in @($Rows)) {
    if ($null -eq $r) { continue }
    if (-not (Test-UvicornAppLine -CommandLine ([string]$r.CommandLine))) { continue }
    $inVenv = ([string]$r.ExecutablePath).StartsWith($venvRoot, [StringComparison]::OrdinalIgnoreCase)
    $parentInVenv = $false
    $parent = $byPid[[int]$r.ParentProcessId]
    if ($null -ne $parent -and [int]$parent.ProcessId -ne [int]$r.ProcessId) {
      $parentInVenv = ([string]$parent.ExecutablePath).StartsWith($venvRoot, [StringComparison]::OrdinalIgnoreCase) -and
                      (Test-UvicornAppLine -CommandLine ([string]$parent.CommandLine))
    }
    if ($inVenv -or $parentInVenv) { $r }
  }
}

function Test-UvicornAppLine {
  param([string]$CommandLine)
  return (($CommandLine -match '(?i)(^|[\s"\\/])uvicorn([\s"]|$)') -and ($CommandLine -match '(?i)(^|[\s"])app:app([\s"]|$)'))
}

function Get-PortListenerPid {
  param([int]$Port)
  try {
    $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop
    $c | ForEach-Object { [int]$_.OwningProcess } | Sort-Object -Unique
  } catch { }
}

function Get-ServiceNow {
  <# @{ Service = <rows>; Listeners = <pids> } from the live process table. Throws when the table
     cannot be read, because "could not look" must not read as "nothing running". #>
  param([string]$SidecarDir, [int]$Port)
  $rows = Get-CimInstance Win32_Process -Filter "Name = 'python.exe'"
  $svc = Select-SidecarServiceProcess -Rows $rows -SidecarDir $SidecarDir
  $svc = @($svc | Where-Object { $null -ne $_ })
  $lis = Get-PortListenerPid -Port $Port
  $lis = @($lis | Where-Object { $null -ne $_ })
  return @{ Service = $svc; Listeners = $lis }
}

# ---------------------------------------------------------------------------
if ($SelfTest) {
  $fails = @(); $ran = @()
  function Case {
    param([string]$Label, [string]$Name, [bool]$Ok, [string]$Detail = '')
    $script:ran += $Name
    if (-not $Ok) { $script:fails += "$Label $Name" }
    '  {0,-14} {1,-62} {2}' -f $Label, $Name, $(if ($Ok) { 'ok' } else { "FAIL $Detail" })
  }
  function Row([int]$ProcId, [int]$ParentId, [string]$Exe, [string]$Cmd) {
    [pscustomobject]@{ ProcessId = $ProcId; ParentProcessId = $ParentId; ExecutablePath = $Exe; CommandLine = $Cmd }
  }
  function PidsOf($Rows, [string]$Dir) {
    $m = Select-SidecarServiceProcess -Rows $Rows -SidecarDir $Dir
    $m = @($m | Where-Object { $null -ne $_ })
    return (($m | ForEach-Object { [int]$_.ProcessId } | Sort-Object) -join ',')
  }

  $dir = 'C:\Fake\Repo\sidecar'
  $venvPy = 'C:\Fake\Repo\sidecar\.venv\Scripts\python.exe'
  $basePy = 'C:\Fake\Python312\python.exe'
  $svcCmd = '"' + $venvPy + '" -m uvicorn app:app --host 127.0.0.1 --port 8077'
  $childCmd = '"' + $basePy + '" -m uvicorn app:app --host 127.0.0.1 --port 8077'
  $redirector = Row 100 1 $venvPy $svcCmd
  $listener = Row 101 100 $basePy $childCmd

  # MUST FIRE: the founding trap. The venv redirector AND the base-interpreter child it spawned, and
  # the child is the one holding the socket. Matching the executable path alone finds only pid 100.
  Case 'MUST FIRE' 'the redirector and its base-interpreter child both match' `
    ((PidsOf @($redirector, $listener) $dir) -eq '100,101') (PidsOf @($redirector, $listener) $dir)
  Case 'MUST FIRE' 'a service launched straight from the venv interpreter matches' `
    ((PidsOf @((Row 200 1 $venvPy $svcCmd)) $dir) -eq '200')

  # MUST NOT FIRE: the nightly's own sweep runs under the SAME venv and must never be stopped.
  $sweepCmd = '"' + $venvPy + '" sweep.py --defs data\commodity-defs-graph.json'
  $sweep = Row 300 1 $venvPy $sweepCmd
  $sweepChild = Row 301 300 $basePy ('"' + $basePy + '" sweep.py --defs data\commodity-defs-graph.json')
  Case 'MUST NOT FIRE' 'the nightly sweep under the same venv is not the service' `
    ((PidsOf @($sweep, $sweepChild) $dir) -eq '')
  # MUST NOT FIRE: a uvicorn app:app belonging to some OTHER project is not ours to stop.
  Case 'MUST NOT FIRE' 'another project''s uvicorn app:app is not the service' `
    ((PidsOf @((Row 400 1 'C:\Other\.venv\Scripts\python.exe' '"C:\Other\.venv\Scripts\python.exe" -m uvicorn app:app'),
               (Row 401 400 $basePy ('"' + $basePy + '" -m uvicorn app:app'))) $dir) -eq '')
  # MUST NOT FIRE: a sibling directory whose name merely STARTS with .venv is a different tree.
  Case 'MUST NOT FIRE' 'a .venv-old sibling does not match on a prefix' `
    ((PidsOf @((Row 500 1 'C:\Fake\Repo\sidecar\.venv-old\Scripts\python.exe' $svcCmd)) $dir) -eq '')
  # MUST NOT FIRE: a base-interpreter child of the venv that is NOT uvicorn (a pip, a REPL).
  Case 'MUST NOT FIRE' 'a non-uvicorn child of a service parent is not stopped' `
    ((PidsOf @($redirector, (Row 102 100 $basePy ('"' + $basePy + '" -m pip list'))) $dir) -eq '100')
  # MUST NOT FIRE: nothing running counts ZERO, never one. @($null).Count is 1 in this language.
  $none = Select-SidecarServiceProcess -Rows @() -SidecarDir $dir
  $none = @($none | Where-Object { $null -ne $_ })
  Case 'MUST NOT FIRE' 'an empty process table counts 0, never 1' ($none.Count -eq 0) "count=$($none.Count)"

  # CLEAN TWIN: the path comparison is case-insensitive, as Windows paths are.
  Case 'CLEAN TWIN' 'an upper-cased executable path still matches' `
    ((PidsOf @((Row 600 1 $venvPy.ToUpper() $svcCmd)) $dir) -eq '600')
  # CLEAN TWIN: an app named app:application, or a module named uvicornish, does not count as ours,
  # while the plain spelling still does - the token boundary holds in both directions.
  Case 'CLEAN TWIN' 'token boundaries: app:app matches, app:application does not' `
    ((Test-UvicornAppLine '-m uvicorn app:app --port 8077') -and
     -not (Test-UvicornAppLine '-m uvicorn app:application --port 8077') -and
     -not (Test-UvicornAppLine '-m uvicornish app:app'))

  # MUST FIRE: this file and the launcher agree on the ASGI target, the server and the port. A
  # renamed target would make this stopper blind in silence. NEEDLES BUILT BY CONCATENATION.
  $launcher = Join-Path $SidecarDir ('start-' + 'sidecar.ps1')
  $lSrc = if (Test-Path -LiteralPath $launcher) { [IO.File]::ReadAllText($launcher) } else { '' }
  Case 'MUST FIRE' 'the launcher still launches uvicorn app:app' `
    ($lSrc.Contains("'" + 'uvi' + 'corn' + "'") -and $lSrc.Contains("'" + 'app:' + 'app' + "'"))
  Case 'MUST FIRE' 'the launcher default port and this default port agree' `
    (($lSrc -match '\$Port\s*=\s*(\d+)') -and ([int]$Matches[1] -eq $Port)) "launcher says $($Matches[1]), this says $Port"

  ''
  if ($fails.Count -gt 0) {
    "stop-sidecar selftest: $($fails.Count) FAILED of $($ran.Count)"
    $fails | ForEach-Object { "  $_" }
    Exit-Guard -Name 'STOP-SIDECAR-SELFTEST' -Code 1 -Summary "failed=$($fails.Count) of $($ran.Count)"
  }
  "stop-sidecar selftest: $($ran.Count) of $($ran.Count) cases pass"
  Exit-Guard -Name 'STOP-SIDECAR-SELFTEST' -Code 0 -Summary "cases=$($ran.Count)"
}

Invoke-Guard -Name 'STOP-SIDECAR' -Body {
  "stop-sidecar: port $Port, service shape = uvicorn app:app under $(Join-Path $MatchDir '.venv')"
  if (-not (Test-Path -LiteralPath (Join-Path $MatchDir '.venv'))) {
    "  note                  : no .venv under $MatchDir - a service from this checkout cannot exist; the port check still runs"
  }
  try {
    $now = Get-ServiceNow -SidecarDir $MatchDir -Port $Port
  } catch {
    "  COULD NOT EVALUATE: the process table could not be read ($($_.Exception.Message))"
    Exit-Guard -Name 'STOP-SIDECAR' -Code 3 -Summary 'blind=process-table-unreadable'
  }
  $svcPids = @($now.Service | ForEach-Object { [int]$_.ProcessId })
  foreach ($r in $now.Service) {
    "  service process       : pid {0} (parent {1}) {2}" -f $r.ProcessId, $r.ParentProcessId, $r.ExecutablePath
  }
  "  port $Port listeners   : $(if ($now.Listeners.Count) { $now.Listeners -join ', ' } else { 'none' })"
  $foreign = @($now.Listeners | Where-Object { $svcPids -notcontains $_ })

  if ($now.Service.Count -eq 0) {
    if ($foreign.Count) {
      "  NOT STOPPED: port $Port is held by pid $($foreign -join ', '), which is not the sidecar service"
      Exit-Guard -Name 'STOP-SIDECAR' -Code 1 -Summary "service=0 foreign_listener=$($foreign -join '+')"
    }
    "  nothing to stop"
    Exit-Guard -Name 'STOP-SIDECAR' -Code 0 -Summary 'service=0 stopped=0 port=free'
  }
  if ($ListOnly) {
    Exit-Guard -Name 'STOP-SIDECAR' -Code 0 -Summary "service=$($now.Service.Count) listed-only"
  }

  foreach ($p in $svcPids) {
    try { Stop-Process -Id $p -Force -ErrorAction Stop } catch { "  stop pid $p : $($_.Exception.Message)" }
  }
  # IT WAITS ON THE PROCESS TABLE AND THE PORT, never on a sleep. Stop-Process returns before a
  # process holding CUDA memory has released it, and a caller that trusted the return would hand
  # llama-server a card the service still occupies.
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $WaitSec) {
    $after = Get-ServiceNow -SidecarDir $MatchDir -Port $Port
    if ($after.Service.Count -eq 0 -and $after.Listeners.Count -eq 0) {
      "  verified              : no service process and port $Port free after {0:N1}s" -f $sw.Elapsed.TotalSeconds
      Exit-Guard -Name 'STOP-SIDECAR' -Code 0 -Summary "service=$($svcPids.Count) stopped=$($svcPids.Count) port=free"
    }
    Start-Sleep -Milliseconds 500
  }
  $after = Get-ServiceNow -SidecarDir $MatchDir -Port $Port
  "  STILL RUNNING after ${WaitSec}s: service=$($after.Service.Count) listeners=$($after.Listeners -join ',')"
  Exit-Guard -Name 'STOP-SIDECAR' -Code 1 -Summary "service=$($after.Service.Count) stopped=no"
}
