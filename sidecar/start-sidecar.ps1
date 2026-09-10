<#
  Start the semantic sidecar, and wait until it actually answers.

  WHY THIS LIVES IN sidecar\ AND NOT IN ops\. A module owns how it starts. The first version of
  ops\sidecar-watchdog.ps1 knew this module's venv layout and uvicorn arguments itself, and
  ops\audit-cross-module-reach.ps1 correctly called that a new reach into another module's
  internals: the watchdog's job is to DECIDE whether to start the service, not to know how.
  Splitting it puts the interpreter path and the ASGI target in the one directory that has to
  change when they change, and leaves the watchdog calling a front door.

  IT WAITS ON /health, NEVER ON A SLEEP. A fixed sleep cannot tell "the service came up" from
  "it is still importing torch" from "it died on line 1", and this estate has paid for that
  distinction. The wait CONDITION is the assertion; when it never becomes true the wait fails
  loudly rather than returning a service nobody checked.

  IT DOES NOT DECIDE WHETHER STARTING IS WISE. The GPU window belongs to
  `TC Graph Nightly Matching` from 21:30 to its hard stop, and refusing to take the card during
  those hours is the watchdog's ruling to make. Run by hand outside that window, or let the
  watchdog call it.

  SCOPE OF A CLEAN REPORT: SOUND about reachability, UNSOUND about usefulness. A 200 from
  /health means the process is listening. It does not mean the models load or that the GPU has
  the VRAM they will want; the first real request pays that, deliberately (see app.py).
#>
[CmdletBinding()]
param(
  [switch]$SelfTest,
  [int]$WaitSec = 90,
  [int]$Port = 8077,
  [string]$BindHost = '127.0.0.1'
)

$ErrorActionPreference = 'Stop'
$SidecarDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $SidecarDir
. (Join-Path $RepoRoot 'lib\guard-contract.ps1')

function Get-SidecarPython {
  <# The interpreter this service runs under. ITS OWN venv, never the estate's Python312:
     app.py imports fastapi, torch and sentence-transformers, none of which is installed in
     the workspace interpreter, so a run under the wrong one dies on the first import with a
     message about fastapi rather than about the interpreter. #>
  param([string]$SidecarDir)
  $venv = Join-Path $SidecarDir '.venv\Scripts\python.exe'
  if (Test-Path -LiteralPath $venv) { return $venv }
  return $null
}

function Test-SidecarHealth {
  param([string]$Url, [int]$TimeoutSec = 3)
  try {
    $r = Invoke-WebRequest -Uri ("$Url/health") -TimeoutSec $TimeoutSec -UseBasicParsing
    if ($r.StatusCode -ne 200) { return $false }
    return [bool](($r.Content | ConvertFrom-Json).ok)
  } catch {
    return $false
  }
}

function Start-SidecarProcess {
  <# Launch and wait. Returns @{ Started=<bool>; Why=<string>; Pid=<int or 0> }.
     Never throws: every caller wants a verdict, and an exception here would make a watchdog
     page about itself rather than about the service. #>
  param([string]$SidecarDir, [string]$BindHost, [int]$Port, [int]$WaitSec)
  $url = "http://${BindHost}:$Port"
  if (Test-SidecarHealth -Url $url) {
    return @{ Started = $true; Why = 'already answering /health'; Pid = 0 }
  }
  $py = Get-SidecarPython -SidecarDir $SidecarDir
  if (-not $py) {
    return @{ Started = $false; Why = 'no .venv interpreter in sidecar\'; Pid = 0 }
  }
  $procId = 0
  try {
    $p = Start-Process -FilePath $py `
      -ArgumentList @('-m', 'uvicorn', 'app:app', '--host', $BindHost, '--port', "$Port") `
      -WorkingDirectory $SidecarDir -WindowStyle Hidden -PassThru
    if ($p) { $procId = $p.Id }
  } catch {
    return @{ Started = $false; Why = "launch threw: $($_.Exception.Message)"; Pid = 0 }
  }
  $deadline = (Get-Date).AddSeconds($WaitSec)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    if (Test-SidecarHealth -Url $url) {
      return @{ Started = $true; Why = 'answered /health'; Pid = $procId }
    }
  }
  return @{ Started = $false; Why = "launched but no /health inside ${WaitSec}s"; Pid = $procId }
}

# ---------------------------------------------------------------------------
if ($SelfTest) {
  $fails = @(); $ran = @()
  function Case {
    param([string]$Label, [string]$Name, [bool]$Ok, [string]$Detail = '')
    $script:ran += $Name
    if (-not $Ok) { $script:fails += "$Label $Name" }
    '  {0,-14} {1,-58} {2}' -f $Label, $Name, $(if ($Ok) { 'ok' } else { "FAIL $Detail" })
  }

  # MUST FIRE: the interpreter and the app this launcher names both exist. These are
  # the two facts that rot silently when the venv is rebuilt or the module moves.
  Case 'MUST FIRE' 'the sidecar venv interpreter exists' `
    ($null -ne (Get-SidecarPython -SidecarDir $SidecarDir)) (Join-Path $SidecarDir '.venv')
  Case 'MUST FIRE' 'app.py exists for uvicorn to import as app:app' `
    (Test-Path -LiteralPath (Join-Path $SidecarDir 'app.py'))

  # MUST FIRE: the launcher and README agree on the command. The README is what a person
  # reads at 3am; two spellings of one command is one of them being wrong.
  $mySrc = [IO.File]::ReadAllText($PSCommandPath)
  Case 'MUST FIRE' 'the launch args name app:app' ($mySrc.Contains("'app:app'"))
  # The run line is in app.py's own header, NOT in README.md - checked, and the first
  # version of this fixture asserted the wrong file and went red for that reason. It is
  # the better place for it anyway: the file that IS the target documents how to run it.
  $appPy = Join-Path $SidecarDir 'app.py'
  Case 'MUST FIRE' 'app.py''s header documents the same uvicorn target and port' `
    ((Test-Path -LiteralPath $appPy) -and
     ([IO.File]::ReadAllText($appPy) -match 'uvicorn\s+app:app.*--port\s+8077'))

  # MUST NOT FIRE: a missing venv is a VERDICT, never an exception, or the watchdog
  # that calls this would fail in a way that reads as the service being fine.
  $tmpDir = Join-Path $env:TEMP ("sidecar-start-selftest-{0}" -f $PID)
  $null = New-Item -ItemType Directory -Force $tmpDir
  try {
    Case 'MUST NOT FIRE' 'a directory with no venv returns null, never throws' `
      ($null -eq (Get-SidecarPython -SidecarDir $tmpDir))
    $r = Start-SidecarProcess -SidecarDir $tmpDir -BindHost '127.0.0.1' -Port 9 -WaitSec 1
    Case 'MUST NOT FIRE' 'starting with no venv reports Started=false and WHY' `
      ((-not $r.Started) -and $r.Why -like '*no .venv*') ([string]$r.Why)
  } finally {
    Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
  }

  # CLEAN TWIN: the health probe still answers False on a dead port rather than throwing.
  Case 'CLEAN TWIN' 'an unreachable port is $false, never an exception' `
    ((Test-SidecarHealth -Url 'http://127.0.0.1:9' -TimeoutSec 2) -eq $false)

  ''
  if ($fails.Count -gt 0) {
    "start-sidecar selftest: $($fails.Count) FAILED of $($ran.Count)"
    $fails | ForEach-Object { "  $_" }
    Exit-Guard -Name 'START-SIDECAR-SELFTEST' -Code 1 -Summary "failed=$($fails.Count) of $($ran.Count)"
  }
  "start-sidecar selftest: $($ran.Count) of $($ran.Count) cases pass"
  Exit-Guard -Name 'START-SIDECAR-SELFTEST' -Code 0 -Summary "cases=$($ran.Count)"
}

Invoke-Guard -Name 'START-SIDECAR' -Body {
  $url = "http://${BindHost}:$Port"
  "start-sidecar: $url"
  $r = Start-SidecarProcess -SidecarDir $SidecarDir -BindHost $BindHost -Port $Port -WaitSec $WaitSec
  if ($r.Started) {
    "  OK: $($r.Why)"
    Exit-Guard -Name 'START-SIDECAR' -Code 0 -Summary "started=yes why=$($r.Why)"
  }
  "  FAILED: $($r.Why)"
  Exit-Guard -Name 'START-SIDECAR' -Code 1 -Summary "started=no why=$($r.Why)"
}
