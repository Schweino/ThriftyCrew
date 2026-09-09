<#
  audit-alert-precision.ps1 - how often each alert, when it fires, is actually right.

  WHY THIS EXISTS (2026-09-07, backlog E22's open half). Precision is a property of a detector AND the
  rate at which the thing it detects occurs. Every `-SelfTest` here drives a must-fire fixture and its
  twin - a 50% base rate by construction, which measures recall honestly and overstates precision
  enormously. So the fixture verdict cannot tell you whether an alert is worth reading. Only its live
  firings can, and until `grocery/triage-close.ps1` shipped, nothing recorded what a firing turned out
  to MEAN: "RESOLVED on re-measurement, the signal no longer holds" and "Rolling condition by design"
  are opposite outcomes written in identical prose, across 124 closed items.

  WHAT IT REPORTS, and what it refuses to. Per alert type: hits, false alarms, and the two outcomes
  that are neither. It states a precision only when there are enough judged closes to have one
  (backlog E21) and it always prints the DENOMINATOR beside the rate (backlog E20). Three closed
  alerts do not make a 33% precision; they make "too few to say", and a number that reads as a
  measurement and is one coin flip is worse than no number because it gets quoted.

  WHAT IT FAILS ON. An item closed on or after the cutoff with no disposition - that is a judgement
  that happened and was not written down. Items closed BEFORE the cutoff are exempt, because
  back-filling them would mean guessing the disposition from prose, which is the exact judgement this
  machinery exists to stop being guessed. Green on day one, by construction.

  DATA-DEPENDENT, SO IT IS NOT IN run-gates. `grocery/triage-queue.json` is gitignored, so a worktree
  or a clean checkout has no queue and this would be BLIND there - the split `run-gates.ps1`'s own
  header describes. Its pure half is covered by `grocery/triage-close.ps1 -SelfTest`, which run-gates
  does discover.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number (backlog E2).
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([string]$QueueFile, [int]$MinCases = 5)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $here 'triage-lib.ps1')
if (-not $QueueFile) { $QueueFile = Join-Path $here 'triage-queue.json' }

if (-not (Test-Path -LiteralPath $QueueFile)) {
  Write-Output ("ALERT PRECISION BLIND: {0} does not exist, so nothing was checked. That is the expected state in a worktree - the queue is gitignored - and it is NOT evidence that every close was judged." -f $QueueFile)
  Exit-Guard -Name 'alert-precision' -Summary 'blind=no-queue' -Code 3
}
$raw = Get-Content $QueueFile -Raw -Encoding UTF8
$q = $null
if ($raw -and $raw.Trim()) { try { $q = $raw | ConvertFrom-Json } catch { } }
if (-not $q) {
  Write-Output 'ALERT PRECISION BLIND: the queue did not parse. An unreadable queue is not a clean one.'
  Exit-Guard -Name 'alert-precision' -Summary 'blind=unparseable' -Code 3
}
# ASSIGN, THEN WRAP - never @(Get-Thing ...) inline. [[ps-json-array-collapse]]
$items = @($q.items)
if (-not $items.Count) {
  Write-Output 'ALERT PRECISION BLIND: the queue parsed and holds zero items, which means the shape moved rather than the backlog being clear.'
  Exit-Guard -Name 'alert-precision' -Summary 'blind=no-items' -Code 3
}

$rows = Get-TcPrecision -Items $items -MinCases $MinCases
$rows = @($rows)
$resolved = @($items | Where-Object { [string]$_.status -eq 'resolved' }).Count
$judged = 0
foreach ($r in $rows) { $judged += $r.Judged + $r.Neither }

Write-Output ("  {0} item(s) in the queue, {1} resolved, {2} carrying a disposition." -f $items.Count, $resolved, $judged)
if (-not $rows.Count) {
  Write-Output '  No alert has a judged close yet, so no precision is claimed for any of them. That is the honest state on the day the vocabulary shipped, not a pass mark.'
} else {
  foreach ($r in $rows) { Write-Output ("  " + $r.Line) }
}

$missing = Get-TcUndispositioned -Items $items
$missing = @($missing)
foreach ($m in $missing) {
  Write-Output ("  FINDING  {0} ({1}) was resolved at {2} with no disposition" -f $m.id, $m.type, $m.resolved_ts)
}
if ($missing.Count) {
  Write-Output ("ALERT PRECISION AUDIT FAILED: {0} item(s) of {1} were closed without saying what the alert turned out to MEAN. Close through grocery\triage-close.ps1, which requires it. Without that field the queue records that somebody dealt with an alert and loses whether the alert was right, which is the only thing a live precision can be computed from." -f $missing.Count, $items.Count)
  Exit-Guard -Name 'alert-precision' -Summary ("items={0} undispositioned={1}" -f $items.Count, $missing.Count) -Code 2
}
Write-Output ("alert-precision: PASSED - every close on or after {0} says what the alert meant. {1} type(s) have judged closes; a rate is stated only where there are at least {2} of them." -f (Get-TcDispositionCutoff), $rows.Count, $MinCases)
Exit-Guard -Name 'alert-precision' -Summary ("items={0} judged={1} undispositioned=0" -f $items.Count, $judged) -Code 0
