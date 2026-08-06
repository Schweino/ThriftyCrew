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

# ---------------------------------------------------------------- BOARD GENERATION, pinned for both stages
# WHY (2026-08-06): the reviewer froze a 26,013-name routing corpus at 06:44 against comparison-2026-08-05, a
# board build landed at ~06:50, and the developer then implemented against 08-06 data. Three of six items came
# back "deviated" and EVERY deviation traced to the board moving underneath the plan, not to a bad diagnosis:
# coverage gaps re-derived 43/8 against the plan's 51/7, a 21st aisle BLOCK appeared, and a cell the plan
# called an empty gap had been filled by a wrong product. The developer paid a second time for a measurement
# the reviewer had already bought. Nothing here blocks a run - the whole point of this system is that an
# alert never waits - but both stages must be able to name the generation they measured, and starting inside
# a build is worth one line of warning.
$outDir = Join-Path $root 'out'
$cmp = @(Get-ChildItem (Join-Path $outDir 'comparison-*.json') -ErrorAction SilentlyContinue |
         Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object LastWriteTime -Descending)
if (-not $cmp.Count) {
  Write-Output 'BOARD UNKNOWN  no comparison-*.json on disk - measure nothing against "the board" until one exists'
} else {
  $newest = $cmp[0]
  $ageMin = [int]((Get-Date) - $newest.LastWriteTime).TotalMinutes
  Write-Output ("BOARD " + $newest.BaseName + "  built " + $newest.LastWriteTime.ToString('HH:mm:ss') + " (" + $ageMin + " min ago)")
  # MID-BUILD: compare-deals writes candidates-*.json a beat BEFORE comparison-*.json, so candidates being the
  # newer of the two means a build is in flight right now and neither file is a stable thing to measure.
  $cand = @(Get-ChildItem (Join-Path $outDir 'candidates-*.json') -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -match '^candidates-\d{4}-\d{2}-\d{2}$' } | Sort-Object LastWriteTime -Descending)
  if ($cand.Count -and $cand[0].LastWriteTime -gt $newest.LastWriteTime) {
    Write-Output '  MID-BUILD: candidates is newer than comparison, so a board build is writing RIGHT NOW.'
    Write-Output '             Wait for it to finish before measuring, or the plan will be stale on arrival.'
  } elseif ($ageMin -le 10) {
    Write-Output '  JUST LANDED: this board is minutes old, which usually means a build just finished or another'
    Write-Output '               is close behind. Pin this generation in the plan and re-check it before shipping.'
  }
  Write-Output ('  Pin it: the reviewer records this name in board_week, the developer re-checks it before acting,')
  Write-Output ('  and any item whose freshness line names a different generation gets re-measured, not assumed.')
}
exit 0
