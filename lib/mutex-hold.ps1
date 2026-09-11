# mutex-hold.ps1 - hold a named mutex from ANOTHER PROCESS until told to let go, so a fixture can make a locked
# writer's wait time out without racing a clock.
#
# WHY THIS EXISTS (2026-09-11). grocery\send-alert.ps1 waited 10 s for Global\smp-grocery-triage-queue, never
# looked at whether it got it, and rewrote the whole triage queue either way - so an alert the lock's real holder
# had just queued could be overwritten out of existence. The fix is a refusal on the timed-out branch, and a
# refusal nothing drives is a refusal nobody knows still works. A mutex is owned by a THREAD, and in the live
# failure the holder is another powershell.exe, so this holds it from a separate process: the holder takes the
# mutex, writes a ready file, and keeps the mutex until a release file appears.
#
# NO CLOCK DECIDES A CASE. The holder keeps the mutex until it is released, so a caller's timed-out wait is a
# timeout however slow the box is. The numbers below are hang guards only.
#
# A FIXTURE NEVER HOLDS A LIVE NAME. Holding Global\smp-grocery-triage-queue from a self-test would make every real
# alert on this box wait behind run-gates, and a slow enough run would spool them. New-TcFixtureMutexName returns a
# fresh Global\ name, and the script under test takes it as a parameter.
#
# SCOPE OF A CLEAN REPORT: a pass proves that while a hold is up another process cannot take the mutex, and that
# after Stop-TcMutexHold it can, released rather than abandoned. It says nothing about any script under test;
# that is that script's own self-test.
#
# Dot-source:  . (Join-Path $repoRoot 'lib\mutex-hold.ps1')
# Self-test:   powershell -File lib\mutex-hold.ps1 -SelfTest
#
# NO param() BLOCK, for the reason lib\concurrency-probe.ps1 gives: PS 5.1 runs a dot-sourced param() block in the
# CALLER's scope, so a [switch]$SelfTest here would reset the -SelfTest of every caller.
$__mhSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

# Every hold this process started, so Stop-TcMutexHold with no -Hold releases them all: the ALLOCATOR remembers,
# because a fixture that has to remember its own cleanup eventually forgets ([[test-suites-leak-temp-dirs]]).
$script:TcMutexHolds = [Collections.Generic.List[object]]::new()

# HANG GUARDS, not tuned numbers. 60 s for a powershell.exe to start and take an uncontended fixture mutex, which
# is about a second on a quiet box; 300 s for a holder whose fixture died without releasing to give it back alone.
$script:TcMutexHoldStartSec = 60
$script:TcMutexHoldMaxSec = 300

function New-TcFixtureMutexName {
  <# A fresh Global\ mutex name for one fixture. Never a live name, and never the same twice. #>
  param([string]$Prefix = 'tc-fixture-mutex')
  return ('Global\' + $Prefix + '-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
}

function Start-TcMutexHold {
  <# Starts a powershell.exe that takes mutex $Name and keeps it until Stop-TcMutexHold. Returns once the holder has
     it, has failed to get it, or has exited. Held says which; Detail says why. #>
  param([Parameter(Mandatory)][string]$Name, [int]$StartSec = $script:TcMutexHoldStartSec)
  $dir = Join-Path ([IO.Path]::GetTempPath()) ('tc-mutex-hold-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  [void][IO.Directory]::CreateDirectory($dir)
  $u8 = New-Object Text.UTF8Encoding($false)
  # The name travels in a file, never on the command line, so no argument quoting can change it.
  [IO.File]::WriteAllText((Join-Path $dir 'name.txt'), $Name, $u8)
  $holder = @'
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$m = New-Object System.Threading.Mutex($false, ([IO.File]::ReadAllText([IO.Path]::Combine($root, 'name.txt'))))
$held = $false
try { $held = $m.WaitOne(__START_MS__) } catch [System.Threading.AbandonedMutexException] { $held = $true }
if (-not $held) { [IO.File]::WriteAllText([IO.Path]::Combine($root, 'failed.txt'), 'the mutex was not free within the start guard'); exit 2 }
try {
  [IO.File]::WriteAllText([IO.Path]::Combine($root, 'ready.txt'), [string]$PID)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while (-not [IO.File]::Exists([IO.Path]::Combine($root, 'release.txt')) -and $sw.Elapsed.TotalSeconds -lt __MAX_SEC__) { Start-Sleep -Milliseconds 20 }
} finally { $m.ReleaseMutex(); $m.Dispose() }
exit 0
'@
  $holder = $holder.Replace('__START_MS__', [string]($StartSec * 1000)).Replace('__MAX_SEC__', [string]$script:TcMutexHoldMaxSec)
  $hs = Join-Path $dir 'hold.ps1'
  [IO.File]::WriteAllText($hs, $holder, $u8)
  $PS = (Get-Command powershell).Source
  $p = Start-Process -FilePath $PS -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $hs + '"')) -PassThru -NoNewWindow
  $null = $p.Handle   # keeps the handle, so ExitCode is readable after the process is gone
  $ready = Join-Path $dir 'ready.txt'
  $failed = Join-Path $dir 'failed.txt'
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while (-not [IO.File]::Exists($ready) -and -not [IO.File]::Exists($failed) -and -not $p.HasExited -and $sw.Elapsed.TotalSeconds -lt ($StartSec + 30)) {
    Start-Sleep -Milliseconds 20
  }
  $held = [IO.File]::Exists($ready)
  $detail = if ($held) { ('holder pid ' + $p.Id + ' holds ' + $Name) }
    elseif ([IO.File]::Exists($failed)) { ('holder could not take ' + $Name + ': ' + [IO.File]::ReadAllText($failed)) }
    elseif ($p.HasExited) { ('holder exited ' + $p.ExitCode + ' before taking ' + $Name) }
    else { ('holder did not report within ' + ($StartSec + 30) + ' s') }
  $hold = [pscustomobject]@{ Name = $Name; Dir = $dir; Process = $p; Held = $held; Detail = $detail }
  [void]$script:TcMutexHolds.Add($hold)
  return $hold
}

function Stop-TcMutexHold {
  <# Releases one hold, or with no -Hold every hold this process started. Waits for the holder to exit (a hang
     guard, then a kill, which abandons the mutex rather than wedging it) and removes its directory. #>
  param($Hold)
  $all = if ($Hold) { @($Hold) } else { @($script:TcMutexHolds.ToArray()) }
  foreach ($h in $all) {
    try { [IO.File]::WriteAllText((Join-Path $h.Dir 'release.txt'), 'x') } catch { }
    try { if (-not $h.Process.WaitForExit(60000)) { $h.Process.Kill() } } catch { }
    Remove-Item -LiteralPath $h.Dir -Recurse -Force -ErrorAction SilentlyContinue
    [void]$script:TcMutexHolds.Remove($h)
  }
}

if ($__mhSelfTest) {
  $ErrorActionPreference = 'Stop'
  $script:n = 0; $script:bad = 0
  function T([string]$What, [bool]$Cond, [string]$Detail = '') {
    $script:n++
    if ($Cond) { Write-Output ('  ok    ' + $What) }
    else { $script:bad++; Write-Output ('  FAIL  ' + $What + $(if ($Detail) { ' -> ' + $Detail } else { '' })) }
  }
  try {
    $name = New-TcFixtureMutexName 'tc-mutex-hold-selftest'
    $name2 = New-TcFixtureMutexName 'tc-mutex-hold-selftest'
    T 'MUST NOT FIRE  a fixture name is never the live triage-queue lock, and two calls never share one' `
      ($name -ne 'Global\smp-grocery-triage-queue' -and $name -like 'Global\tc-mutex-hold-selftest-*' -and $name -ne $name2) "$name / $name2"

    $hold = Start-TcMutexHold -Name $name
    T 'the holder process took the mutex' $hold.Held $hold.Detail
    $m = New-Object System.Threading.Mutex($false, $name)
    try {
      $got = $false
      try { $got = $m.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
      if ($got) { $m.ReleaseMutex() }
      T 'MUST FIRE  while the hold is up, THIS process cannot take the mutex' ($hold.Held -and -not $got) ("held=$($hold.Held) got=$got")

      Stop-TcMutexHold -Hold $hold
      $got2 = $false; $abandoned = $false
      # A hang guard, not a speed bar: an uncontended mutex is taken at once.
      try { $got2 = $m.WaitOne(30000) } catch [System.Threading.AbandonedMutexException] { $got2 = $true; $abandoned = $true }
      if ($got2) { $m.ReleaseMutex() }
      T 'CLEAN TWIN after Stop-TcMutexHold this process takes the mutex, released and not abandoned' ($got2 -and -not $abandoned) ("got=$got2 abandoned=$abandoned")
      T 'CLEAN TWIN and the holder exited 0 and its directory is gone' ($hold.Process.HasExited -and $hold.Process.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $hold.Dir)) ("exited=$($hold.Process.HasExited) code=$($hold.Process.ExitCode) dir=$(Test-Path -LiteralPath $hold.Dir)")
    } finally { $m.Dispose() }
  } finally {
    Stop-TcMutexHold
  }
  Write-Output ('SELFTEST: {0}/{1} pass' -f ($script:n - $script:bad), $script:n)
  Write-Output ('MUTEX-HOLD-COMPLETE cases={0} failed={1}' -f $script:n, $script:bad)
  if ($script:bad -gt 0) { exit 1 }
  exit 0
}
