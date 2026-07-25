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
try { $q = Get-Content $qFile -Raw | ConvertFrom-Json } catch { Write-Output 'DUE  triage-queue.json is UNREADABLE - that itself is the first item to fix'; exit 0 }
$open = @($q.items | Where-Object { $_.status -eq 'open' })
$needsBrad = @($q.items | Where-Object { $_.status -eq 'needs-brad' })
if ($open.Count -eq 0) {
  $nb = ''; if ($needsBrad.Count) { $nb = ' (' + $needsBrad.Count + ' item(s) parked needs-brad - do not re-triage, they are his)' }
  Write-Output ('IDLE  triage queue clear' + $nb); exit 0
}
Write-Output ("DUE  " + $open.Count + " open alert(s) to triage:")
foreach ($i in $open) { Write-Output ('  [' + $i.id + '] x' + $i.count + '  ' + $i.subject) }
exit 0
