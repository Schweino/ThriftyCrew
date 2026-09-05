<#
audit-coverage-regression.ps1 - catch a store QUIETLY LOSING coverage between two boards.

WHY THIS EXISTS
  On 2026-07-16 a bare `compare-deals.ps1` re-run cut Sam's Club from 251 priced cells to 116. Nothing caught
  it. Not one guard, because every guard we had asks "is this cell RIGHT?" and none asks "is this cell STILL
  THERE?":
    - the publish coverage gate checks a FLOOR (>= ~15 cells/store). 116 sails past it.
    - audit-board-consistency only looks at chips that EXIST, so a vanished chip is simply out of scope.
    - a missing store renders as a legitimate "doesn't carry" tile - indistinguishable, to a human or an audit,
      from a store that genuinely does not stock the item.
  So the board can lose a third of a store and still score 100% on every check. Brad found this one by eye
  ("Sams is still missing links for boneless chicken breast"). That is the failure mode this guard closes:
  coverage is a THING WE MEASURE OVER TIME, not a floor.

WHAT IT DOES
  Diffs the newest board against the previous DATED board and fails when a store's priced-cell count drops by
  more than -MaxDropPct AND more than -MaxDropCells (both, so a tiny store's noise is not a fire alarm).

INTENTIONAL DROPS
  A drop is sometimes correct - Fareway's 286 cells were pulled on purpose when the price-mode gate proved they
  were Instacart DELIVERY prices, not shelf prices. Those go in coverage-ack.json with a reason and an expiry,
  so an intentional drop is silent ONCE and re-arms itself later instead of becoming a permanent blind spot.

EXIT CODES   0 = ok   2 = unacknowledged regression (publish should HOLD)
#>
param(
  [string]$OutDir = (Join-Path $PSScriptRoot 'out'),
  [string]$New = "",              # newest board; default = newest comparison-*.json
  [string]$Prev = "",             # baseline;    default = newest comparison-*.json with an EARLIER date
  [int]$MaxDropPct = 10,
  [int]$MaxDropCells = 15,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage

function BoardFiles {
  Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -match 'comparison-(\d{4}-\d{2}-\d{2})$' } | Sort-Object Name -Descending
}
$files = @(BoardFiles)
if (-not $New) { if (-not $files.Count) { Write-Output 'coverage-regression: no board files; nothing to check.'; exit 3 }; $New = $files[0].FullName }
$newDate = if ([IO.Path]::GetFileNameWithoutExtension($New) -match '(\d{4}-\d{2}-\d{2})$') { $Matches[1] } else { '' }
if (-not $Prev) {
  # baseline = newest board from a DIFFERENT (earlier) date. Same-date rebuilds must not be their own baseline,
  # or a regression introduced by today's second run would compare clean against today's first run.
  $p = @($files | Where-Object { $_.BaseName -notmatch [regex]::Escape($newDate) + '$' } | Select-Object -First 1)
  if (-not $p.Count) { Write-Output 'coverage-regression: no earlier board to compare against; nothing to check.'; exit 3 }
  $Prev = $p[0].FullName
}

function StoreCounts($path) {
  $j = Read-JsonFile $path
  $h = @{}
  foreach ($r in $j.comparison) { foreach ($s in $r.stores) { $k = [string]$s.store; if (-not $h.ContainsKey($k)) { $h[$k] = 0 }; $h[$k]++ } }
  return @{ stores = $h; rows = @($j.comparison).Count }
}
# EXIT 3 = "could not evaluate", distinct from 0 = "evaluated, all good". guards.ps1 ran this with | Out-Null
# and relabelled every exit 0 as "ok  no store lost coverage vs the previous board" - so the two honest
# "nothing to check" sentences above were DISCARDED and reported as a pass. Not exotic: guard 12's own essay
# notes out\comparison-*.json is gitignored on purpose, so a fresh clone or a cloud runner has exactly ONE
# board and the second bail-out fires every single time. This is the only guard that can see the Sam's
# 251 -> 116 class; the publish gate itself only enforces a floor.
$a = StoreCounts $Prev
$b = StoreCounts $New
# THIRD zero-examination path, downstream of both bail-outs and easy to miss: StoreCounts does not throw on a
# board whose `comparison` array is empty or renamed - `foreach ($r in $null)` iterates zero times - so a
# degenerate baseline yields $was = 0 for every store, every drop negative, no failures, exit 0. Reproduced
# with a {"comparison":[]} baseline: every store printed as "0 -> 334 ... ok", then "OK - no store lost
# coverage." A fix that only patches the two bail-outs above leaves this path wide open.
if ($a.stores.Count -eq 0) { Write-Output 'coverage-regression: baseline board has ZERO priced cells; nothing to compare against.'; exit 3 }

# acks: [{ store, reason, expires:'YYYY-MM-DD' }]
$ackPath = Join-Path $OutDir 'coverage-ack.json'
$acks = @{}
if (Test-Path $ackPath) {
  foreach ($e in @((Read-JsonFile $ackPath).acks)) {
    $exp = [string]$e.expires
    if ($exp -and $newDate -and ([datetime]$exp -lt [datetime]$newDate)) { continue }   # expired -> guard re-arms
    $acks[[string]$e.store] = $e
  }
}

$rows = @(); $fail = @()
foreach ($s in ($a.stores.Keys + $b.stores.Keys | Select-Object -Unique | Sort-Object)) {
  $was = if ($a.stores.ContainsKey($s)) { $a.stores[$s] } else { 0 }
  $now = if ($b.stores.ContainsKey($s)) { $b.stores[$s] } else { 0 }
  $drop = $was - $now
  $pct = if ($was -gt 0) { [math]::Round(($drop / $was) * 100, 1) } else { 0 }
  $bad = ($drop -gt $MaxDropCells -and $pct -gt $MaxDropPct)
  $ack = $acks.ContainsKey($s)
  $rows += [pscustomobject]@{ store = $s; was = $was; now = $now; drop = $drop; pct = $pct; regression = $bad; acked = $ack }
  if ($bad -and -not $ack) { $fail += $rows[-1] }
}

$report = [ordered]@{
  checked      = $newDate
  new_board    = (Split-Path $New -Leaf)
  prev_board   = (Split-Path $Prev -Leaf)
  rows_was     = $a.rows
  rows_now     = $b.rows
  thresholds   = @{ max_drop_pct = $MaxDropPct; max_drop_cells = $MaxDropCells }
  stores       = $rows
  fail_count   = $fail.Count
}
($report | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $OutDir 'coverage-regression.json') -Encoding UTF8

if (-not $Quiet) {
  Write-Output ("coverage-regression: " + (Split-Path $Prev -Leaf) + "  ->  " + (Split-Path $New -Leaf))
  Write-Output ("{0,-14}{1,8}{2,8}{3,8}{4,9}   {5}" -f 'store', 'was', 'now', 'drop', 'pct', 'verdict')
  foreach ($r in $rows) {
    $v = if ($r.regression -and $r.acked) { 'drop ACKED (intentional)' } elseif ($r.regression) { 'REGRESSION' } elseif ($r.drop -gt 0) { 'ok (within tolerance)' } else { 'ok' }
    Write-Output ("{0,-14}{1,8}{2,8}{3,8}{4,9}   {5}" -f $r.store, $r.was, $r.now, $r.drop, ($r.pct.ToString() + '%'), $v)
  }
  Write-Output ("rows: " + $a.rows + " -> " + $b.rows)
}
if ($fail.Count) {
  Write-Output ''
  Write-Output ("coverage-regression: FAIL - " + $fail.Count + " store(s) lost coverage with no acknowledgement:")
  foreach ($f in $fail) { Write-Output ("  " + $f.store + ": " + $f.was + " -> " + $f.now + " (-" + $f.drop + " cells, -" + $f.pct + "%)") }
  Write-Output "A store does not quietly shrink. Either a capture came back partial, a rename broke the matcher,"
  Write-Output "or the engine was invoked differently. Fix it, or - if the drop is correct - add the store to"
  Write-Output "out\coverage-ack.json with a reason and an expiry date."
  exit 2
}
Write-Output 'coverage-regression: OK - no store lost coverage.'
exit 0
