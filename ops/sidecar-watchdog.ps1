<#
  Is the semantic sidecar alive, and if not and the GPU is free, start it.

  WS 0b of design\PLAN-brain-v2-2026-09-09.md.

  WHY IT EXISTS, MEASURED. On 2026-09-09 the sidecar on 127.0.0.1:8077 was down for the whole
  day and nothing noticed. The recall hook's semantic leg is designed to fall back to lexical
  in silence, and it did - `recall-leg-log.jsonl` records 723 semantic offers on 09-08 and 208
  lexical / 0 semantic on 09-09 - while `recall-brain.py` printed that state with the
  parenthetical "which is normal". Two costs, both invisible:

    * RETRIEVAL QUALITY. Measured in course/PLAN-consult-first: the semantic leg answers 19 of
      30 consult questions and BM25 answers 10. A day on the fallback is a day at the worse
      number with nothing saying so.
    * WALL CLOCK. Every prompt paid two 1.5 s timeouts. The hook's own timing rows read p50
      3,195 ms against a pre-registered 200 ms bar. recall_semantic.py's circuit breaker now
      caps that; this is the other half, which is getting the service back.

  THE GPU WINDOW IS NOT NEGOTIATED HERE. `TC Graph Nightly Matching` owns the card from 21:30
  to its hard stop, and the estate's rule is that the nightly hands the card back before 07:00
  so the capture chain never finds it held. A watchdog that started a second CUDA process at
  0200 would be taking the card from the job that was promised it. So inside the window this
  reports DEFERRED and starts nothing, and the recall hook stays on its lexical fallback for
  those hours by design. Ruling R1 of the plan; the default was ruled here, not assumed silently.
  THIS FILE IS ONLY HALF OF R1. Refusing to START in the window does not take down a service this
  file restored at 06:30, and until 2026-09-10 nothing did, so the nightly's `serve` stage would find
  it resident at 21:30 and go BLIND. The other half is the nightly's `handoff` stage, which calls
  sidecar\stop-sidecar.ps1 before its sweep. The watchdog does not stop anything itself: at 21:30 it
  and the nightly fire on the same minute, and only the nightly knows when it needs the card.

  THE WINDOW END IS READ, NEVER HARD-CODED. It comes out of nightly.ps1's own `-HardStop`
  default, for the same reason the ad-timing window is read from capture-policy: two copies of a
  schedule is one schedule and one stale comment. `[CORRECTED 2026-09-10]` Until this date it was
  NOT read on any real run - see Resolve-GpuWindowEnd - and the two copies agreed at 06:30, so
  nothing showed it. KNOWN LIMIT: the registered nightly task passes `-HardStop 06:30` on its
  command line, which is a third copy this does not read.

  SCOPE OF A CLEAN REPORT: SOUND about reachability, UNSOUND about usefulness. A 200 from
  /health means the process is listening; it does not mean the models load, that the GPU has
  VRAM free, or that /recall-search will answer. Those cost a real request and this must stay
  cheap enough to run every 15 minutes.
#>
[CmdletBinding()]
param(
  [switch]$SelfTest,
  [switch]$Alert,
  [string]$Url = 'http://127.0.0.1:8077',
  [int]$StartWaitSec = 90,
  [string]$GpuWindowStart = '21:30',
  [string]$GpuWindowEnd = '06:30'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot 'lib\guard-contract.ps1')
# EVERY HIDDEN SCHEDULED TASK ROUTES THROUGH THE ONE RUN-RECORD LIBRARY (backlog E29,
# gated by ops\audit-run-log-claims.ps1). A task that runs with -WindowStyle Hidden and
# writes no run record is a task whose death is indistinguishable from a quiet day, which
# is exactly the failure this watchdog exists to catch in the sidecar. It would be an odd
# thing to be guilty of.
. (Join-Path $RepoRoot 'grocery\run-log-lib.ps1')

# ops OWNS ITS OWN OUTPUT. The stamp began life under grocery\out\logs\ beside the other
# watchdog's, and ops\audit-cross-module-reach.ps1 correctly called that a reach into another
# module's internals. Where a file lives is a statement about who is responsible for it.
$script:StampPath = Join-Path $RepoRoot 'ops\out\sidecar-watchdog-stamp.json'
# THE WINDOW END COMES FROM THE NIGHTLY'S OWN DECLARED DEFAULT, not from a status file it
# writes. Two reasons and the second is the one that matters: the status file only exists
# AFTER a run, so a fresh checkout would silently fall back to a parameter default; and the
# `-HardStop` parameter is the nightly's front door, which is what a sibling module is
# entitled to read. Reading its output directory instead would be reaching past it.
$script:NightlyScript = Join-Path $RepoRoot 'graph\pipeline\nightly.ps1'

function Get-SidecarHealth {
  <# $true when the service answers /health with ok. Never throws: an unreachable port and a
     refused connection are the SAME answer to this question, and a watchdog that threw on the
     ordinary case would page about itself. #>
  param([string]$Url, [int]$TimeoutSec = 3)
  try {
    $r = Invoke-WebRequest -Uri ("$Url/health") -TimeoutSec $TimeoutSec -UseBasicParsing
    if ($r.StatusCode -ne 200) { return $false }
    $d = $r.Content | ConvertFrom-Json
    return [bool]$d.ok
  } catch {
    return $false
  }
}

function Test-InGpuWindow {
  <# Is `now` inside the nightly's window? The window WRAPS midnight, which is the whole
     reason this is a function and not an inline comparison: 21:30 to 06:30 is two intervals
     on a clock face, and `$now -ge $start -and $now -le $end` is false for every minute of it. #>
  param([datetime]$Now, [string]$Start, [string]$End)
  $s = [datetime]::ParseExact($Start, 'HH:mm', $null).TimeOfDay
  $e = [datetime]::ParseExact($End, 'HH:mm', $null).TimeOfDay
  $t = $Now.TimeOfDay
  if ($s -le $e) { return ($t -ge $s -and $t -lt $e) }
  return ($t -ge $s -or $t -lt $e)
}

function Get-NightlyHardStop {
  <# The window end, read out of the nightly's own `-HardStop` parameter default.

     WHY THE SOURCE IS SAID OUT LOUD. A default silently standing in for a read is how two
     schedules drift apart while both look configured, so the caller prints which it used. #>
  param([string]$Path, [string]$Fallback)
  try {
    if (Test-Path -LiteralPath $Path) {
      $src = [IO.File]::ReadAllText($Path)
      $m = [regex]::Match($src, '\$HardStop\s*=\s*''(\d{2}:\d{2})''')
      if ($m.Success) {
        return @{ Value = $m.Groups[1].Value; Source = 'nightly.ps1 -HardStop default' }
      }
    }
  } catch { }
  return @{ Value = $Fallback; Source = 'parameter default (nightly.ps1 unreadable)' }
}

function Resolve-GpuWindowEnd {
  <# The window end the RUN uses. One call site, and the self-test drives this same function.

     WHY THIS EXISTS, MEASURED 2026-09-10. Both callers of Get-NightlyHardStop passed
     `$script:StatusPath`, a variable nothing in this file ever assigned (the path variable is
     `$script:NightlyScript`). An unset variable binds an empty string, Test-Path threw inside the
     reader's try, and every scheduled run from WS 0b's first night took the parameter default
     while its transcript said "end read from parameter default (nightly.ps1 unreadable)". The
     self-test passed throughout, because its case called the reader the same broken way and
     asserted only that SOME value with SOME source came back - which the fallback supplies. A
     reader tested through its own call and not through production's cannot see production's
     call site. #>
  param([string]$Fallback)
  return (Get-NightlyHardStop -Path $script:NightlyScript -Fallback $Fallback)
}

function Start-Sidecar {
  <# Ask the sidecar to start itself, through its own launcher.

     THE HOW LIVES IN sidecar\start-sidecar.ps1 AND THAT IS THE POINT. This file decides
     WHETHER the service should be started - the GPU window, the health probe, the alert. It
     used to also know the venv layout and the uvicorn arguments, and the cross-module reach
     ratchet correctly called that new coupling: a watchdog that knows another module's
     internals breaks when that module reorganises, and nothing points at the watchdog when
     it does. #>
  param([string]$Url, [int]$WaitSec, [string]$RepoRoot)
  $launcher = Join-Path $RepoRoot 'sidecar\start-sidecar.ps1'
  if (-not (Test-Path -LiteralPath $launcher)) {
    return @{ Started = $false; Why = 'sidecar\start-sidecar.ps1 is missing' }
  }
  try {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $launcher -WaitSec $WaitSec
    $code = $LASTEXITCODE
  } catch {
    return @{ Started = $false; Why = "launcher threw: $($_.Exception.Message)" }
  }
  # THE VERDICT IS THE EXIT CODE, AND COMPLETION IS THE MARKER. Read separately, because a
  # launcher that died halfway would otherwise be indistinguishable from one that reported a
  # clean failure - which is the whole reason lib\guard-contract.ps1 exists.
  $done = Test-GuardComplete -Output $out -Name 'START-SIDECAR'
  if (-not $done) {
    return @{ Started = $false; Why = 'the launcher did not finish (no START-SIDECAR-COMPLETE)' }
  }
  if ($code -eq 0 -and (Get-SidecarHealth -Url $Url)) {
    return @{ Started = $true; Why = 'launcher reported started and /health answers' }
  }
  $tail = @($out | Where-Object { "$_".Trim() } | Select-Object -Last 1)
  return @{ Started = $false; Why = "launcher exit $code; $tail" }
}

function Write-Stamp {
  <# The proof-of-life file expected-automations.json watches. Written on EVERY path including
     the deferred one, because a watchdog that stamps only when it acted looks dead on every
     quiet day - and quiet is the normal case for a watchdog. #>
  param([string]$Path, [hashtable]$Data)
  try {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force $dir }
    $Data['written'] = (Get-Date).ToString('s')
    $json = $Data | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
  } catch { }
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

  # MUST FIRE: the founding trap of this file. The window wraps midnight, so the
  # naive comparison is false for every single minute the nightly is running.
  $mid = [datetime]'2026-09-09 02:00'
  Case 'MUST FIRE' 'a wrapping window contains 02:00' `
    (Test-InGpuWindow -Now $mid -Start '21:30' -End '06:30')
  Case 'MUST FIRE' 'a wrapping window contains 22:00' `
    (Test-InGpuWindow -Now ([datetime]'2026-09-09 22:00') -Start '21:30' -End '06:30')
  Case 'MUST FIRE' 'the boundary minute 21:30 is INSIDE' `
    (Test-InGpuWindow -Now ([datetime]'2026-09-09 21:30') -Start '21:30' -End '06:30')

  # MUST NOT FIRE: the hours the sidecar is wanted must not read as the window,
  # or the watchdog defers forever and the leg never comes back.
  Case 'MUST NOT FIRE' 'midday is NOT in the window' `
    (-not (Test-InGpuWindow -Now ([datetime]'2026-09-09 12:00') -Start '21:30' -End '06:30'))
  Case 'MUST NOT FIRE' 'the boundary minute 06:30 is OUTSIDE' `
    (-not (Test-InGpuWindow -Now ([datetime]'2026-09-09 06:30') -Start '21:30' -End '06:30'))
  Case 'MUST NOT FIRE' 'a NON-wrapping window still behaves' `
    ((Test-InGpuWindow -Now ([datetime]'2026-09-09 10:00') -Start '09:00' -End '11:00') -and
     (-not (Test-InGpuWindow -Now ([datetime]'2026-09-09 12:00') -Start '09:00' -End '11:00')))

  # CLEAN TWIN: the health probe answers False rather than throwing, which is what
  # lets every other path stay simple.
  Case 'CLEAN TWIN' 'an unreachable port is $false, never an exception' `
    ((Get-SidecarHealth -Url 'http://127.0.0.1:9' -TimeoutSec 2) -eq $false)

  # MUST FIRE: the founding bug of 2026-09-10. The window end the RUN resolves comes out of
  # nightly.ps1, not out of the fallback. THE FALLBACK IS AN IMPOSSIBLE TIME ON PURPOSE: the
  # nightly's default and this file's parameter both say 06:30, so a fallback of 06:30 would let
  # a missed read pass as an agreeing number, which is exactly how the unset variable survived.
  $hs = Resolve-GpuWindowEnd -Fallback '99:99'
  Case 'MUST FIRE' 'the run reads its window end from nightly.ps1, not the fallback' `
    ($hs.Value -match '^\d{2}:\d{2}$' -and $hs.Value -ne '99:99' -and
     $hs.Source -eq 'nightly.ps1 -HardStop default') "got $($hs.Value) from $($hs.Source)"

  # CLEAN TWIN: the reader returns the value a copy DECLARES, so a pass above means nightly.ps1
  # was read, not that 06:30 happens to be what the regex falls through to.
  $tmpNightly = Join-Path $env:TEMP ("sidecar-wd-nightly-{0}.ps1" -f $PID)
  [IO.File]::WriteAllText($tmpNightly, "param(`n  [string]`$HardStop = '05:45'`n)`n",
    (New-Object Text.UTF8Encoding($false)))
  try {
    $hsCopy = Get-NightlyHardStop -Path $tmpNightly -Fallback '06:30'
    Case 'CLEAN TWIN' 'a hard stop that disagrees with the fallback is read at its own value' `
      ($hsCopy.Value -eq '05:45' -and $hsCopy.Source -eq 'nightly.ps1 -HardStop default') `
      "got $($hsCopy.Value) from $($hsCopy.Source)"
  } finally {
    Remove-Item -LiteralPath $tmpNightly -ErrorAction SilentlyContinue
  }
  $hs2 = Get-NightlyHardStop -Path (Join-Path $env:TEMP 'no-such-status-file.json') -Fallback '05:15'
  Case 'CLEAN TWIN' 'a missing status file falls back and SAYS it fell back' `
    ($hs2.Value -eq '05:15' -and $hs2.Source -like '*parameter default*')

  # MUST FIRE: the launch CONTRACT, asserted statically.
  #
  # WHY STATIC AND NOT LIVE, STATED SO NOBODY READS THIS AS THE FULL TEST. The live
  # restart path was NOT exercised on 2026-09-09 because the first run fell at 21:33,
  # inside the nightly's window, and the whole point of the deferral is that a
  # watchdog does not take the card from the job that was promised it. Overriding the
  # window to make a green line appear would be weakening the rule to get past it.
  # So this asserts what can rot without anybody running it: that the front door is
  # there, that it declares a self-test of its own (which owns the venv and uvicorn
  # assertions this file used to duplicate), and that its port and this file's default
  # URL still agree. The live path is proved by the scheduled run after 06:30.
  $launcherPath = Join-Path $RepoRoot 'sidecar\start-sidecar.ps1'
  Case 'MUST FIRE' 'the sidecar front door exists' (Test-Path -LiteralPath $launcherPath)
  $lSrc = if (Test-Path -LiteralPath $launcherPath) { [IO.File]::ReadAllText($launcherPath) } else { '' }
  Case 'MUST FIRE' 'the front door carries its own self-test' `
    ($lSrc -match '\[switch\]\$SelfTest')
  Case 'MUST FIRE' 'the launcher default port and this URL agree' `
    (($lSrc -match '\$Port\s*=\s*8077') -and $Url.Contains('8077')) `
    'a watchdog probing one port while the launcher opens another would report DOWN forever'

  # MUST NOT FIRE: this file must not re-learn the internals it just handed back. If
  # the venv path or the ASGI target reappears here, the split has been undone and the
  # cross-module ratchet is the only thing that would notice.
  # THE NEEDLES ARE BUILT BY CONCATENATION and the scan is scoped to the FUNCTION, not
  # to the rest of the file. Both corrections came from this fixture's first run, and
  # both are the estate's own rule: a self-test that greps its own source cannot fail,
  # and here it could not PASS - the assertion's own text contains the strings it hunts,
  # so scanning from the function to end-of-file matched the fixture rather than the code.
  $mySrc = [IO.File]::ReadAllText($PSCommandPath)
  $fnStart = $mySrc.IndexOf('function Start-Sidecar')
  $fnEnd = $mySrc.IndexOf('function Write-Stamp')
  $body = if ($fnStart -ge 0 -and $fnEnd -gt $fnStart) { $mySrc.Substring($fnStart, $fnEnd - $fnStart) } else { '' }
  $needleVenv = '.' + 'venv'
  $needleAsgi = 'app' + ':' + 'app'
  Case 'MUST NOT FIRE' 'the watchdog does not know the venv layout or the ASGI target' `
    (($body.Length -gt 200) -and (-not $body.Contains($needleVenv)) -and
     (-not $body.Contains($needleAsgi))) `
    'starting the service is the sidecar module''s job, not this one''s'
  # CLEAN TWIN: the scan can still SEE those strings, so a pass means they are absent
  # rather than that the scan is looking at nothing.
  Case 'CLEAN TWIN' 'the same scan finds those needles in the launcher that owns them' `
    ($lSrc.Contains($needleVenv) -and $lSrc.Contains($needleAsgi))

  # CLEAN TWIN: the stamp is writable, because a watchdog nobody can watch is the
  # shape this file exists to remove.
  $tmpStamp = Join-Path $env:TEMP ("sidecar-wd-selftest-{0}.json" -f $PID)
  Write-Stamp -Path $tmpStamp -Data @{ state = 'selftest' }
  Case 'CLEAN TWIN' 'the stamp file is written and parses as JSON' `
    ((Test-Path -LiteralPath $tmpStamp) -and
     ((Get-Content -Raw $tmpStamp | ConvertFrom-Json).state -eq 'selftest'))
  Remove-Item -LiteralPath $tmpStamp -ErrorAction SilentlyContinue

  ''
  if ($fails.Count -gt 0) {
    "sidecar-watchdog selftest: $($fails.Count) FAILED of $($ran.Count)"
    $fails | ForEach-Object { "  $_" }
    Exit-Guard -Name 'SIDECAR-WATCHDOG-SELFTEST' -Code 1 -Summary "failed=$($fails.Count) of $($ran.Count)"
  }
  "sidecar-watchdog selftest: $($ran.Count) of $($ran.Count) cases pass"
  Exit-Guard -Name 'SIDECAR-WATCHDOG-SELFTEST' -Code 0 -Summary "cases=$($ran.Count)"
}

# THE TRANSCRIPT IS STOPPED IN A `finally`, because every exit path here goes through
# Exit-Guard, which calls `exit`. Measured and documented in lib\guard-contract.ps1: `exit`
# inside a scriptblock DOES run an enclosing finally but does NOT run the statements after
# the call. A Stop-RunLog placed after Invoke-Guard would therefore never run on any real
# path - only on the one nobody takes.
$script:RunLog = Start-RunLog -Name 'sidecar-watchdog' -OutDir (Join-Path $RepoRoot 'ops\out')
try {
Invoke-Guard -Name 'SIDECAR-WATCHDOG' -Body {
  $now = Get-Date
  $hs = Resolve-GpuWindowEnd -Fallback $GpuWindowEnd
  $windowEnd = $hs.Value
  $inWindow = Test-InGpuWindow -Now $now -Start $GpuWindowStart -End $windowEnd

  "sidecar-watchdog: probing $Url"
  "  gpu window            : $GpuWindowStart to $windowEnd  (end read from $($hs.Source))"
  "  now                   : $($now.ToString('HH:mm')), in window = $inWindow"

  $up = Get-SidecarHealth -Url $Url
  if ($up) {
    "  state                 : UP"
    Write-Stamp -Path $script:StampPath -Data @{ state = 'up'; url = $Url; acted = $false }
    Exit-Guard -Name 'SIDECAR-WATCHDOG' -Code 0 -Summary 'state=up acted=no'
  }

  if ($inWindow) {
    "  state                 : DOWN, and DEFERRED - the nightly owns the card until $windowEnd"
    "  consequence           : the recall hook stays on its lexical leg for these hours, by design"
    Write-Stamp -Path $script:StampPath -Data @{ state = 'deferred'; url = $Url; acted = $false;
                                                  reason = "gpu window until $windowEnd" }
    Exit-Guard -Name 'SIDECAR-WATCHDOG' -Code 0 -Summary 'state=deferred acted=no'
  }

  "  state                 : DOWN, and the card is free. Starting it."
  $r = Start-Sidecar -Url $Url -WaitSec $StartWaitSec -RepoRoot $RepoRoot
  if ($r.Started) {
    "  restart               : OK ($($r.Why))"
    Write-Stamp -Path $script:StampPath -Data @{ state = 'restarted'; url = $Url; acted = $true }
    Exit-Guard -Name 'SIDECAR-WATCHDOG' -Code 0 -Summary 'state=restarted acted=yes'
  }

  "  restart               : FAILED ($($r.Why))"
  "  NOTE: this is a REPORT of a failed restart, not a broken watchdog. The recall"
  "  hook's circuit breaker keeps the cost bounded meanwhile; retrieval quality is"
  "  the thing that is degraded, and it is degraded silently without this line."
  if ($Alert) {
    try {
      $alert = Join-Path $RepoRoot 'grocery\send-alert.ps1'
      if (Test-Path -LiteralPath $alert) {
        # NO -Type PARAMETER EXISTS. send-alert.ps1 derives its once-per-day suppression
        # key from the SUBJECT with digits and dates stripped, so the subject must be
        # stable across runs and the varying detail belongs in the body. Passing -Type
        # would have been refused outright by ops\audit-arg-binding.ps1, which is the
        # right outcome - a scoped call must never silently run unscoped.
        & $alert -Subject 'Semantic sidecar is down and would not restart' `
          -Body "Probe of $Url failed and the restart did not answer /health: $($r.Why)" `
          -Emitter 'ops\sidecar-watchdog.ps1'
      }
    } catch { }
  }
  Write-Stamp -Path $script:StampPath -Data @{ state = 'down'; url = $Url; acted = $true;
                                               reason = [string]$r.Why }
  Exit-Guard -Name 'SIDECAR-WATCHDOG' -Code 1 -Summary 'state=down acted=yes-failed'
}
} finally {
  # A CRASH MUST NOT BE RECORDED AS rc=0. `[CORRECTED 2026-09-10]` This passed a literal 0,
  # and the sibling digest proved what that costs: its body threw, the transcript closed with
  # "finished rc=0", and the one record whose job is to say a hidden run died said it was
  # fine. lib\guard-contract.ps1 sets $script:TcGuardMarkerWritten only when Exit-Guard writes
  # the completion marker, so its absence here means the body never finished. Stop-RunLog
  # tolerates a $null path: logging must never be the reason a run fails.
  $rcLog = if ($script:TcGuardMarkerWritten) { 0 } else { 1 }
  Stop-RunLog -ExitCode $rcLog -Path $script:RunLog
}
