<#
  triage-due.ps1 - 2-second guard for the grocery-alert-triage scheduled agent.
  Prints IDLE (nothing open) or DUE with a compact list of open queue items. The agent runs hourly while
  the Claude app is open precisely so that a queue written while the app was CLOSED gets drained on the
  first tick after Brad opens it - the guard is what makes that cheap.
#>
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$qFile = Join-Path $root 'triage-queue.json'
if (-not (Test-Path $qFile)) { Write-Output 'IDLE  no triage queue file - no alert has ever fired'; exit 0 }
# FAIL CLOSED. 2026-07-28: send-alert.ps1 rewrote this file in place, and a read landing inside that window
# returned an empty string. '' | ConvertFrom-Json yields $null in PS 5.1 WITHOUT throwing, so the catch below
# never fired, $q.items was $null, and the guard printed IDLE while 5 real alerts sat open - the tick was
# skipped and Brad had to notice the emails himself. Writes are atomic now; this retries anyway (a swap is
# still a moment where the handle can miss) and treats "cannot read a queue that exists" as DUE, never IDLE.
$q = $null
for ($try = 1; $try -le 4; $try++) {
  try {
    $raw = Get-Content $qFile -Raw -ErrorAction Stop
    if ($raw -and $raw.Trim()) { $q = $raw | ConvertFrom-Json }
  } catch { $q = $null }
  if ($q -and $q.PSObject.Properties['items']) { break }
  $q = $null
  Start-Sleep -Milliseconds 250
}
if (-not $q) { Write-Output 'DUE  triage-queue.json exists but read back empty/unparseable after 4 tries - that itself is the first item to fix'; exit 0 }
$open = @($q.items | Where-Object { $_.status -eq 'open' })
# a spool file means send-alert could not reach the queue at all - those alerts are unworked by definition
$spools = @(Get-ChildItem (Join-Path $root 'triage-spool-*.jsonl') -ErrorAction SilentlyContinue)
if ($spools.Count -gt 0) {
  Write-Output ('DUE  ' + $spools.Count + ' triage SPOOL file(s) - send-alert could not write the queue; drain and delete them:')
  foreach ($s in $spools) { Write-Output ('  ' + $s.Name) }
}
$needsBrad = @($q.items | Where-Object { $_.status -eq 'needs-brad' })
if ($open.Count -eq 0 -and $spools.Count -gt 0) { exit 0 }   # spool lines above already said DUE
if ($open.Count -eq 0) {
  $nb = ''; if ($needsBrad.Count) { $nb = ' (' + $needsBrad.Count + ' item(s) parked needs-brad - do not re-triage, they are his)' }
  Write-Output ('IDLE  triage queue clear' + $nb); exit 0
}
Write-Output ("DUE  " + $open.Count + " open alert(s) to triage:")
foreach ($i in $open) { Write-Output ('  [' + $i.id + '] x' + $i.count + '  ' + $i.subject) }
exit 0
