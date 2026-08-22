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

  Exit code mirrors the word (0 = FREE, 1 = HELD) so a script can branch on either.
#>
[CmdletBinding()]
param()
$m = New-Object System.Threading.Mutex($false, 'Global\tc-capture-run')
$got = $false
try { $got = $m.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] {
  # An abandoned mutex means the holder died without releasing. Nothing is running, so this is FREE -
  # but say so, because a crashed chain is worth knowing about.
  $got = $true
  Write-Output 'NOTE: the previous holder abandoned the mutex - a capture-run died without releasing it.'
}
if ($got) {
  try { $m.ReleaseMutex() } catch { }
  Write-Output 'FREE'
  exit 0
}
Write-Output 'HELD'
exit 1
