<#
  chain-idle.ps1 - is a capture-run chain running right now? Prints FREE or HELD.

  WHY THIS IS A FILE AND NOT A ONE-LINER. The 09:00 stage-two agent has to answer this before it
  runs any builder, and the inline version is a nest of $ and backslash escaping that gets mangled
  by whatever is quoting it (it was mangled on first writing - 'Global\tc-capture-run' became a
  literal tab). A named mutex check that silently tests the WRONG NAME always answers FREE, which is
  the answer that causes the damage: stage two would build straight into the middle of the 0800
  chain, both writing out\regular and touching the same git index.

  WHY IT MATTERS. Measured 2026-08-22: the 0800 task's downstream chain ran 08:12-08:43, 31 minutes.
  Stage two was originally scheduled at 08:30 - squarely inside it - and was moved to 09:00 because
  of this. The mutex check is the belt to that braces: the chain can run long, and a fixed clock gap
  is an assumption while the mutex is a fact.

  AN ABANDONED LOCK IS NOT FREE WHILE A CAPTURE-RUN IS ALIVE (2026-09-23,
  design\PLAN-bot-checkout-self-heal-2026-09-23.md W4.1 step 7). Until then abandoned meant "the holder died, nothing
  is running", so this printed FREE and RELEASED the lock. Since W4.1 a killed parent can leave its re-executed child
  capturing, committing and pushing, and that release did two kinds of damage: it told stage two to build into the
  child's tree, and it erased the abandonment, the only signal the next capture-run uses to find the orphan (proved in
  a scratch harness during the lane's review: the next run then got a clean lock and never looked). Now an abandoned
  lock asks grocery\capture-run-lock-lib.ps1's Get-CaptureRunOrphanHolder, which fails closed: a live capture-run, or a
  probe that could not look, prints HELD and exits 1 WITHOUT releasing, so this process's exit abandons the lock again
  for capture-run to see. Only an abandoned lock with no capture-run alive is FREE, and released, as before.

  Exit code mirrors the word (0 = FREE, 1 = HELD) so a script can branch on either.
  -MutexName, -StatusFile and -ScriptPattern are fixture seams (grocery\test-capture-run-sync.ps1, CHAIN-IDLE group);
  a real run passes none of them.
#>
[CmdletBinding()]
param(
  [string]$MutexName = 'Global\tc-capture-run',
  [string]$StatusFile = '',
  [string]$ScriptPattern = ''
)
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile, for the status record
. (Join-Path $PSScriptRoot 'capture-run-lock-lib.ps1')             # Get-CaptureRunOrphanHolder
if (-not $StatusFile) { $StatusFile = Join-Path $PSScriptRoot 'out\logs\capture-run-status.json' }
$m = New-Object System.Threading.Mutex($false, $MutexName)
$got = $false
$abandoned = $false
try { $got = $m.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $got = $true; $abandoned = $true }
if ($abandoned) {
  $oArgs = @{ StatusFile = $StatusFile }
  if ($ScriptPattern) { $oArgs['Pattern'] = $ScriptPattern }
  $o = Get-CaptureRunOrphanHolder @oArgs
  if ($o.alive) {
    # NOT released: this process now owns the lock, and its exit abandons it again, which is what the next capture-run
    # reads to go looking for the orphan.
    Write-Output ('NOTE: the capture-run lock was abandoned, and ' + $o.why + ' - the synced child of a killed parent may still be working the tree.')
    Write-Output 'HELD'
    exit 1
  }
  Write-Output ('NOTE: the previous holder abandoned the mutex - a capture-run died without releasing it, and ' + $o.why + '.')
}
if ($got) {
  try { $m.ReleaseMutex() } catch { }
  Write-Output 'FREE'
  exit 0
}
Write-Output 'HELD'
exit 1
