# keep-awake.ps1 - hold the machine awake for the life of a scheduled run.
#
# WHY THIS EXISTS (triage queue 2026-09-18-8491bf, weekly lane plan-2026-09-25-13). The daily chain did not run
# on 2026-09-15 or 2026-09-16. The System event log says why: the box was asleep, and TC Grocery Daily Capture
# 0800's WakeToRun timer DID wake it (Power-Troubleshooter 1 at 07:59:36 both days), and Kernel-Power 42 put it
# back to sleep at 08:02:01, two and a half minutes later, before capture-run had written its log. That is the
# Windows UNATTENDED idle timeout: a wake with no user present sleeps again after about two minutes unless some
# process holds a system-required power request. Task Scheduler's WakeToRun wakes the machine; it does not keep
# it awake. So every scheduled run on this box was one idle timeout from being cut off after a wake.
#
# Enter-TcKeepAwake asks SetThreadExecutionState for ES_CONTINUOUS | ES_SYSTEM_REQUIRED. The request belongs to
# the calling THREAD and Windows drops it when the thread or process ends, so a run that dies never leaves the box
# pinned awake; Exit-TcKeepAwake clears it early. It never throws: a failure returns ok=$false with the reason,
# because being unable to hold the box awake must never stop the run that asked (the day before this file existed).
# Idempotent: asking twice sets the same flags.
#
# Dot-source:  . (Join-Path $repoRoot 'lib\keep-awake.ps1')
# Self-test:   powershell -NoProfile -File lib\keep-awake.ps1 -SelfTest
#
# NO param() BLOCK HERE, DELIBERATELY - dot-sourced under PS 5.1 a param() block runs in the CALLER's scope and
# would reset the caller's own -SelfTest. Same rule as lib\append-line.ps1.
$__kaSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

$script:TcEsContinuous     = [uint32]2147483648   # ES_CONTINUOUS 0x80000000
$script:TcEsSystemRequired = [uint32]1            # ES_SYSTEM_REQUIRED 0x00000001

function Initialize-TcKeepAwakeType {
  if (-not ('TcKeepAwake.Native' -as [type])) {
    Add-Type -Namespace TcKeepAwake -Name Native -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
  }
}

function Enter-TcKeepAwake {
  <# Holds ES_CONTINUOUS | ES_SYSTEM_REQUIRED on this thread. Returns @{ ok; previous; why }. Never throws. #>
  try {
    Initialize-TcKeepAwakeType
    $prev = [TcKeepAwake.Native]::SetThreadExecutionState($script:TcEsContinuous -bor $script:TcEsSystemRequired)
    if ($prev -eq 0) { return [pscustomobject]@{ ok = $false; previous = 0; why = 'SetThreadExecutionState returned 0 (refused)' } }
    return [pscustomobject]@{ ok = $true; previous = $prev; why = 'system-required held until this process ends' }
  } catch {
    return [pscustomobject]@{ ok = $false; previous = 0; why = ('could not ask: ' + $_.Exception.Message) }
  }
}

function Exit-TcKeepAwake {
  <# Clears this thread's request (ES_CONTINUOUS alone). Returns the flags that were held, 0 on failure. Never throws. #>
  try { Initialize-TcKeepAwakeType; return [TcKeepAwake.Native]::SetThreadExecutionState($script:TcEsContinuous) } catch { return [uint32]0 }
}

if ($__kaSelfTest) {
  $ErrorActionPreference = 'Stop'
  $script:cases = 0; $script:failed = 0
  function Case([string]$Label, [string]$Name, [bool]$Ok, [string]$Got) {
    $script:cases++
    if ($Ok) { Write-Output ("  ok    {0}  {1}" -f $Label, $Name) }
    else { $script:failed++; Write-Output ("  X     {0}  {1}   got: {2}" -f $Label, $Name, $Got) }
  }
  try {
    # The mechanism, read back from the API itself: the flags a later call reports as PREVIOUS are the flags held.
    $e = Enter-TcKeepAwake
    $held = Exit-TcKeepAwake
    Case 'MUST FIRE' 'Enter-TcKeepAwake holds ES_SYSTEM_REQUIRED on the thread (founding bug: the 08:00 run re-slept 2.5 min after its wake)' ($e.ok -and (($held -band $script:TcEsSystemRequired) -ne 0) -and (($held -band $script:TcEsContinuous) -ne 0)) ("ok=$($e.ok) why='$($e.why)' held=0x{0:X8}" -f $held)
    $after = Exit-TcKeepAwake
    Case 'CLEAN TWIN' 'Exit-TcKeepAwake releases it, so the next read shows ES_CONTINUOUS alone and no system-required request' ((($after -band $script:TcEsSystemRequired) -eq 0) -and $after -eq $script:TcEsContinuous) ("after=0x{0:X8}" -f $after)
    $e2 = Enter-TcKeepAwake; $e3 = Enter-TcKeepAwake; $held2 = Exit-TcKeepAwake
    Case 'CLEAN TWIN' 'asking twice is idempotent: the second ask reports the first ask''s flags and the same flags stay held' ($e2.ok -and $e3.ok -and $e3.previous -eq ($script:TcEsContinuous -bor $script:TcEsSystemRequired) -and $held2 -eq $e3.previous) ("e3.previous=0x{0:X8} held2=0x{1:X8}" -f $e3.previous, $held2)
    # Wiring: capture-run asks before it takes its run lock, so every scheduled Kind is held awake from its start.
    $cr = Join-Path (Split-Path $PSScriptRoot -Parent) 'grocery\capture-run.ps1'
    $crText = [IO.File]::ReadAllText($cr)
    $callNeedle = 'Enter-' + 'TcKeepAwake'
    $lockNeedle = '$script:RunMutex = New-' + 'Object'
    $ci = $crText.IndexOf($callNeedle); $li = $crText.IndexOf($lockNeedle)
    Case 'MUST FIRE' 'grocery\capture-run.ps1 calls Enter-TcKeepAwake before it asks for Global\tc-capture-run' ($ci -ge 0 -and $li -ge 0 -and $ci -lt $li) ("call@$ci lock@$li")
  } catch {
    $script:failed++; Write-Output ("  X     threw: " + $_.Exception.Message)
  }
  if ($script:failed) {
    Write-Output ("keep-awake SELF-TEST FAIL ({0} of {1})" -f $script:failed, $script:cases)
    Write-Output ("KEEP-AWAKE-COMPLETE cases={0} failed={1}" -f $script:cases, $script:failed)
    exit 1
  }
  if ($script:cases -ne 4) { Write-Output ("keep-awake SELF-TEST FAIL (ran {0} of 4 cases)" -f $script:cases); exit 1 }
  Write-Output ("keep-awake SELF-TEST PASS ({0} cases)" -f $script:cases)
  Write-Output ("KEEP-AWAKE-COMPLETE cases={0} failed=0" -f $script:cases)
  exit 0
}
