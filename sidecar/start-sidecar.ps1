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

function Get-SidecarVenvState {
  <# Where does this checkout's venv stand against the path the launcher looks at?
       'present'   - the interpreter Get-SidecarPython names exists.
       'elsewhere' - some directory under sidecar\ carries a pyvenv.cfg, but not the interpreter the
                     launcher names. The venv was rebuilt or moved and the launcher would fail: ROT.
       'absent'    - no venv of any name. A gate-check checkout, a CI runner, a fresh clone. #>
  param([string]$SidecarDir)
  if (Get-SidecarPython -SidecarDir $SidecarDir) { return 'present' }
  $venvs = @(Get-ChildItem -LiteralPath $SidecarDir -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'pyvenv.cfg') })
  if ($venvs.Count) { return 'elsewhere' }
  return 'absent'
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

function Test-SidecarReady {
  <# Is the service USABLE, not merely listening? Pure over a parsed /health body.

     WHY, MEASURED LIVE 2026-09-10. The watchdog's first daytime restart reported OK at 06:30:18
     because /health answered, and the first prompt after it, at 06:30:36, paid 3,205 ms and fell
     back to lexical: /recall-search and then /embed each hit the recall hook's 1.5 s timeout while
     the models loaded inside that very request (/health afterwards: load_seconds 11.7), two
     failures opened the breaker for 60 s, and the next session's prompt skipped the leg as well.
     /health answers BEFORE any model is loaded, by design (app.py loads lazily so that importing
     the module stays cheap), so "answers /health" was the wrong definition of started. #>
  param($Health)
  if ($null -eq $Health) { return $false }
  try { return ([bool]$Health.ok -and [bool]$Health.models_loaded) } catch { return $false }
}

function Get-SidecarHealthBody {
  <# The parsed /health body, or $null. Never throws. #>
  param([string]$Url, [int]$TimeoutSec = 3)
  try {
    $r = Invoke-WebRequest -Uri ("$Url/health") -TimeoutSec $TimeoutSec -UseBasicParsing
    if ($r.StatusCode -ne 200) { return $null }
    return ($r.Content | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function Invoke-SidecarWarm {
  <# One real request, so the models load NOW, on the launcher's clock, instead of inside the first
     prompt's 1.5 s budget. clean=false is the flag the recall hook sends. $true when it answered. #>
  param([string]$Url, [int]$TimeoutSec)
  try {
    $body = '{"texts":["warm"],"clean":false}'
    $r = Invoke-WebRequest -Uri ("$Url/embed") -Method Post -ContentType 'application/json' -Body $body `
      -TimeoutSec ([math]::Max(5, $TimeoutSec)) -UseBasicParsing
    return ($r.StatusCode -eq 200)
  } catch {
    return $false
  }
}

function Complete-SidecarWarm {
  <# Warm a service that already answers /health, then report whether it is READY. The verdict is
     read back from /health, never inferred from the warm call's return: a warm request that timed
     out while another thread finished the load is still a ready service. #>
  param([string]$Url, [datetime]$Deadline, [int]$ProcId, [string]$Prefix)
  if (-not (Test-SidecarReady (Get-SidecarHealthBody -Url $Url))) {
    $left = [int][math]::Max(5, ($Deadline - (Get-Date)).TotalSeconds)
    $null = Invoke-SidecarWarm -Url $Url -TimeoutSec $left
  }
  $h = Get-SidecarHealthBody -Url $Url
  if (Test-SidecarReady $h) {
    return @{ Started = $true; Why = ("$Prefix and loaded its models (load_seconds {0})" -f $h.load_seconds); Pid = $ProcId }
  }
  return @{ Started = $false; Why = "$Prefix but its models did not load before the deadline"; Pid = $ProcId }
}

function Start-SidecarProcess {
  <# Launch, wait for /health, then warm. Returns @{ Started=<bool>; Why=<string>; Pid=<int or 0> }.
     STARTED MEANS READY: /health answers AND the models are loaded (Test-SidecarReady).
     Never throws: every caller wants a verdict, and an exception here would make a watchdog
     page about itself rather than about the service. #>
  param([string]$SidecarDir, [string]$BindHost, [int]$Port, [int]$WaitSec)
  $url = "http://${BindHost}:$Port"
  if (Test-SidecarHealth -Url $url) {
    return (Complete-SidecarWarm -Url $url -Deadline ((Get-Date).AddSeconds($WaitSec)) -ProcId 0 -Prefix 'already answering /health')
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
      return (Complete-SidecarWarm -Url $url -Deadline $deadline -ProcId $procId -Prefix 'answered /health')
    }
  }
  return @{ Started = $false; Why = "launched but no /health inside ${WaitSec}s"; Pid = $procId }
}

# ---------------------------------------------------------------------------
if ($SelfTest) {
  $fails = @(); $ran = @(); $blind = @()
  function Case {
    # -Blind names why a case COULD NOT LOOK. It is neither a pass nor a failure, it is printed as BLIND,
    # and it is counted into the COMPLETE marker's blind= so run-gates can name it on a green run.
    param([string]$Label, [string]$Name, [bool]$Ok, [string]$Detail = '', [string]$Blind = '')
    $script:ran += $Name
    if ($Blind) {
      $script:blind += "$Label $Name"
      return ('  {0,-14} {1,-58} BLIND {2}' -f $Label, $Name, $Blind)
    }
    if (-not $Ok) { $script:fails += "$Label $Name" }
    '  {0,-14} {1,-58} {2}' -f $Label, $Name, $(if ($Ok) { 'ok' } else { "FAIL $Detail" })
  }

  # MUST FIRE: the interpreter and the app this launcher names both exist. These are
  # the two facts that rot silently when the venv is rebuilt or the module moves.
  #
  # BLIND, NOT FAIL, IN A CHECKOUT WITH NO VENV AT ALL (2026-09-11). The venv is gitignored, so a
  # `git worktree add` gate-check checkout, a CI runner and a fresh clone never have one, and this case
  # was red in every one of them for a reason that had nothing to do with the change under test. There it
  # cannot tell "the venv was rebuilt somewhere else" from "this checkout never had a venv", so it says it
  # could not look. It still FAILS when a venv exists under sidecar\ but not where the launcher looks,
  # which is the rot it was written for. A venv deleted outright from the main checkout goes BLIND here
  # and is caught in production instead: ops\sidecar-watchdog.ps1 alerts "Semantic sidecar is down and
  # would not restart" with "no .venv interpreter" as the reason. Seeding a junction to the main
  # checkout's venv was considered and rejected; ops\seed-worktree.ps1's header records why.
  $venvState = Get-SidecarVenvState -SidecarDir $SidecarDir
  Case 'MUST FIRE' 'the sidecar venv interpreter exists' `
    ($venvState -eq 'present') ("venv state '$venvState': a venv exists under sidecar\ but not at " + (Join-Path $SidecarDir '.venv\Scripts\python.exe')) `
    -Blind $(if ($venvState -eq 'absent') { 'no venv of any name under sidecar\ in this checkout, so it cannot tell a mislaid venv from one never built' } else { '' })

  # The three venv states, on temp directories. MUST FIRE is the rot; MUST NOT FIRE is the gate-check
  # checkout this change exists for; CLEAN TWIN is the healthy main checkout still reading as present.
  $vRoot = Join-Path $env:TEMP ("sidecar-venvstate-selftest-{0}" -f $PID)
  try {
    $vMoved = Join-Path $vRoot 'moved'; $vBroken = Join-Path $vRoot 'broken'; $vNone = Join-Path $vRoot 'none'; $vOk = Join-Path $vRoot 'ok'
    foreach ($d in @((Join-Path $vMoved 'venv'), (Join-Path $vBroken '.venv'), $vNone, (Join-Path $vOk '.venv\Scripts'))) {
      $null = New-Item -ItemType Directory -Force $d
    }
    [IO.File]::WriteAllText((Join-Path $vMoved 'venv\pyvenv.cfg'), 'home = x')
    [IO.File]::WriteAllText((Join-Path $vBroken '.venv\pyvenv.cfg'), 'home = x')
    [IO.File]::WriteAllText((Join-Path $vOk '.venv\pyvenv.cfg'), 'home = x')
    [IO.File]::WriteAllText((Join-Path $vOk '.venv\Scripts\python.exe'), '')
    Case 'MUST FIRE' 'a venv rebuilt under another name is ELSEWHERE, so the case fails' `
      ((Get-SidecarVenvState -SidecarDir $vMoved) -eq 'elsewhere') (Get-SidecarVenvState -SidecarDir $vMoved)
    Case 'MUST FIRE' 'a .venv with no Scripts\python.exe is ELSEWHERE, so the case fails' `
      ((Get-SidecarVenvState -SidecarDir $vBroken) -eq 'elsewhere') (Get-SidecarVenvState -SidecarDir $vBroken)
    Case 'MUST NOT FIRE' 'a checkout with no venv of any name is ABSENT - blind, never a failure' `
      ((Get-SidecarVenvState -SidecarDir $vNone) -eq 'absent') (Get-SidecarVenvState -SidecarDir $vNone)
    Case 'CLEAN TWIN' 'a .venv holding the interpreter the launcher names is PRESENT' `
      ((Get-SidecarVenvState -SidecarDir $vOk) -eq 'present') (Get-SidecarVenvState -SidecarDir $vOk)
  } finally {
    Remove-Item -Recurse -Force $vRoot -ErrorAction SilentlyContinue
  }
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

  # MUST FIRE, THE FOUNDING CASE OF 2026-09-10 06:30: /health answered with the models NOT loaded,
  # the launcher called that started, and the first prompt paid the load and fell back to lexical.
  Case 'MUST FIRE' 'a service answering /health with its models unloaded is NOT ready' `
    (-not (Test-SidecarReady ([pscustomobject]@{ ok = $true; models_loaded = $false; load_seconds = $null })))
  Case 'MUST FIRE' 'no /health body at all is not ready, and never an exception' `
    (-not (Test-SidecarReady $null))
  # CLEAN TWIN: a loaded service is ready - the positive half, so the case above is not passing
  # because the function refuses everything.
  Case 'CLEAN TWIN' 'a service with its models loaded IS ready' `
    (Test-SidecarReady ([pscustomobject]@{ ok = $true; models_loaded = $true; load_seconds = 11.7 }))
  # MUST FIRE, STATIC: both success paths go through the warm-then-read-back step, and the warm call
  # sends clean=false. NEEDLES BUILT BY CONCATENATION, and the scan is scoped to the function bodies.
  $fnS = $mySrc.IndexOf('function Start-Sidecar' + 'Process')
  $fnE = $mySrc.IndexOf('# ------------------------------------------' + '---------------------------------')
  $spBody = if ($fnS -ge 0 -and $fnE -gt $fnS) { $mySrc.Substring($fnS, $fnE - $fnS) } else { '' }
  $nComplete = 'Complete-Sidecar' + 'Warm -Url $url'
  $nOldOk = "Why = 'answered " + "/health'; Pid"
  Case 'MUST FIRE' 'both started paths warm and read readiness back, and none returns on /health alone' `
    (($spBody.Length -gt 200) -and (([regex]::Matches($spBody, [regex]::Escape($nComplete))).Count -eq 2) -and
     (-not $spBody.Contains($nOldOk)) -and (-not $spBody.Contains("Started = `$true; Why = 'already " + "answering")))
  $nClean = '"clean"' + ':false'
  Case 'MUST FIRE' 'the warm request sends clean=false, the flag the recall hook uses' ($mySrc.Contains($nClean))

  # CLEAN TWIN: the health probe still answers False on a dead port rather than throwing.
  Case 'CLEAN TWIN' 'an unreachable port is $false, never an exception' `
    ((Test-SidecarHealth -Url 'http://127.0.0.1:9' -TimeoutSec 2) -eq $false)

  ''
  if ($fails.Count -gt 0) {
    "start-sidecar selftest: $($fails.Count) FAILED of $($ran.Count)"
    $fails | ForEach-Object { "  $_" }
    Exit-Guard -Name 'START-SIDECAR-SELFTEST' -Code 1 -Summary "failed=$($fails.Count) of $($ran.Count) blind=$($blind.Count)"
  }
  if ($blind.Count -gt 0) {
    "start-sidecar selftest: $($ran.Count - $blind.Count) of $($ran.Count) cases pass, $($blind.Count) BLIND - could not look, NOT passed:"
    $blind | ForEach-Object { "  $_" }
  } else {
    "start-sidecar selftest: $($ran.Count) of $($ran.Count) cases pass"
  }
  Exit-Guard -Name 'START-SIDECAR-SELFTEST' -Code 0 -Summary "cases=$($ran.Count) blind=$($blind.Count)"
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
