<#
  HOLD SCOPE: cell - names each cell priced from a sale or rollback window that has ended (QUARANTINE-CELL ... value)
  audit-ended-window.ps1 - no published cell may be priced from a window that ended before today.

  WHY (2026-09-26, design\PLAN-board-clock-2026-09-26.md W8, Brad's D2: "If a sale price is dropped, it should be part
  of the automated job to detect that and fix the price on the day after the sale. I think one of our routines should
  be detecting this."). That day the board carried 9 cells whose window had ended 09-23..09-25 - 7 Sam's Club
  rollbacks and 2 Fareway sales - and 5 of them held the "Cheapest" crown on the live site. Two causes, both fixed in
  compare-deals the same day: the engine judged expiry at the ad set's date instead of the real date (W1), and a Sam's
  markdown was typed everyday so its window could never retire it (W1b). THIS FILE IS THE BACKSTOP: after those fixes
  it should never fire, and if a later change reopens either hole, the cell quarantines itself here instead of
  publishing a price the store will not honour. The repair half of D2 is not here: build-sale-windows logs each window's
  refresh_on (end + 1) and capture-policy puts the item at the head of that store's next capture.

  A delegated guards audit (guards.ps1 runs it with the others), in the protocol cell-quarantine-lib.ps1
  Get-TcChildQuarantineScope reads:
      QUARANTINE-CELL <commodity-id>|<store>|value
      QUARANTINE-SCOPE complete cells=<N> stores=0
  'value' because the NUMBER is condemned: a sale price after its sale is not a price the store charges.

  THE BAR: a window whose last day is TODAY is live (the store honours it through closing); one whose last day was
  YESTERDAY has ended. Measured against the real date (-Now in fixtures), never the board's week_of, which is the ad
  set's date and lags the real date whenever no weekly ad is due. Any cell carrying an ended window is named, whatever
  its type: the founding Sam's shape was typed everyday.

  SCOPE OF A CLEAN REPORT: sound for every published cell that carries an ad_to - each one is checked, by construction.
  Unsound about a sale whose window nobody recorded: a cell with no ad_to cannot be judged here, and is not named.

  Exit 0 = no ended window prices this board. 2 = cells named (the scope line follows). 3 = could not evaluate (no
  board, or a board with no comparison): guards reports that as a WARN naming what went unproven, never as a pass.
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([string]$OutDir = '', [string]$BoardFile = '', [string]$Now = '', [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$repo = Split-Path $root -Parent
. (Join-Path $repo 'lib\json-io.ps1')
. (Join-Path $repo 'lib\guard-contract.ps1')
# WHAT THE SELF-TEST READS: in-memory fixture boards only.
# gate-inputs: grocery\audit-ended-window.ps1, lib\json-io.ps1, lib\guard-contract.ps1

# Every published cell whose window ended before $NowS (yyyy-MM-dd). One pure function, so the self-test drives the code
# the live run runs.
function Get-EndedWindowCells($Board, [string]$NowS) {
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($r in @($Board.comparison)) {
    if ($null -eq $r) { continue }
    foreach ($s in @($r.stores)) {
      if ($null -eq $s) { continue }
      $to = [string]$s.ad_to
      if ($to -notmatch '^\d{4}-\d{2}-\d{2}$') { continue }            # no recorded window: not judgeable here
      if ([string]::CompareOrdinal($to, $NowS) -ge 0) { continue }     # ends today or later: live
      $out.Add([pscustomobject]@{ id = [string]$r.id; store = [string]$s.store; type = [string]$s.type; ad_to = $to; basis = [string]$s.ad_basis; per_unit = $s.per_unit; crown = ([string]$r.cheapest_store -eq [string]$s.store) })
    }
  }
  return $out.ToArray()
}

if ($SelfTest) {
  $script:ewRan = 0; $script:ewFail = 0
  function Test-EwCase([string]$Label, [bool]$Ok, [string]$Got) {
    $script:ewRan++
    if ($Ok) { Write-Output ('  ok    ' + $Label) } else { $script:ewFail++; Write-Output ('  FAIL  ' + $Label + '   got: ' + $Got) }
  }
  function New-EwBoard([object[]]$Cells) {
    $rows = @(foreach ($c in $Cells) { [pscustomobject]@{ id = $c[0]; cheapest_store = $c[1]; stores = @([pscustomobject]@{ store = $c[1]; type = $c[2]; ad_to = $c[3]; ad_basis = $c[4]; per_unit = 1.0 }) } })
    return [pscustomobject]@{ week_of = '2026-09-23'; comparison = $rows }
  }
  try {
    # THE FOUNDING SHAPES, from the board of 2026-09-26: a Sam's rollback typed everyday whose TTL window ended 09-24,
    # and a Fareway sale that ended 09-25. Both held the crown.
    $found = New-EwBoard @(@('avocado-oil', "Sam's Club", 'everyday', '2026-09-24', ''), @('black-peppercorns', 'Fareway', 'sale', '2026-09-25', 'store'))
    $f = @(Get-EndedWindowCells $found '2026-09-26')
    Test-EwCase 'MUST FIRE  the Sam''s rollback typed everyday whose window ended 09-24 is named on 09-26' (@($f | Where-Object { $_.id -eq 'avocado-oil' -and $_.store -eq "Sam's Club" }).Count -eq 1) (($f | ForEach-Object { $_.id }) -join ',')
    Test-EwCase 'MUST FIRE  the Fareway sale that ended 09-25 is named on 09-26' (@($f | Where-Object { $_.id -eq 'black-peppercorns' }).Count -eq 1) (($f | ForEach-Object { $_.id }) -join ',')
    # AT THE BAR and ONE STEP PAST IT (one day, the resolution of an ad_to).
    $at = @(Get-EndedWindowCells (New-EwBoard @(,@('milk', 'Aldi', 'sale', '2026-09-26', 'ad'))) '2026-09-26')
    Test-EwCase 'MUST NOT FIRE at the bar  a window whose last day is today (09-26) is live' ($at.Count -eq 0) ('named ' + $at.Count)
    $past = @(Get-EndedWindowCells (New-EwBoard @(,@('milk', 'Aldi', 'sale', '2026-09-25', 'ad'))) '2026-09-26')
    Test-EwCase 'MUST FIRE one step past the bar  a window whose last day was yesterday (09-25) has ended' ($past.Count -eq 1) ('named ' + $past.Count)
    # THE LAG: measured against the real date, never week_of. The fixture board is for the 09-23 ad set.
    $lag = @(Get-EndedWindowCells (New-EwBoard @(,@('milk', 'Aldi', 'sale', '2026-09-24', 'ad'))) '2026-09-26')
    Test-EwCase 'MUST FIRE  a window that ended 09-24 is named on 09-26 though the board is for the 09-23 ad set (week_of would have kept it)' ($lag.Count -eq 1) ('named ' + $lag.Count)
    # CLEAN TWINS.
    $ev = @(Get-EndedWindowCells (New-EwBoard @(,@('rice', 'Walmart', 'everyday', '', ''))) '2026-09-26')
    Test-EwCase 'MUST NOT FIRE  an everyday cell with no window is never named (nothing to judge)' ($ev.Count -eq 0) ('named ' + $ev.Count)
    $fut = @(Get-EndedWindowCells (New-EwBoard @(,@('rice', 'Hy-Vee', 'sale', '2026-10-01', 'ad'))) '2026-09-26')
    Test-EwCase 'MUST NOT FIRE  a sale running to 10-01 is not named' ($fut.Count -eq 0) ('named ' + $fut.Count)
  } catch {
    Test-EwCase 'the self-test ran to its end with no unexpected error' $false ($_.Exception.Message + ' line ' + $_.InvocationInfo.ScriptLineNumber)
  }
  $want = 7
  if ($script:ewRan -ne $want) { Write-Output ('  FAIL  the suite ran ' + $script:ewRan + ' case(s), not the ' + $want + ' it lists'); $script:ewFail++ }
  if ($script:ewFail) { Write-Output ('audit-ended-window SELF-TEST FAIL (' + $script:ewFail + ' of ' + $want + ')'); exit 1 }
  Write-Output ('audit-ended-window SELF-TEST PASS (' + $want + ' of ' + $want + ')')
  exit 0
}

if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $BoardFile) {
  $bf = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  if ($bf) { $BoardFile = $bf.FullName }
}
if (-not $BoardFile -or -not (Test-Path -LiteralPath $BoardFile)) { Write-Output 'BLIND: no comparison board to audit'; Exit-Guard -Name 'audit-ended-window' -Summary 'no board' -Code 3 }
$board = Read-JsonFile $BoardFile
if ($null -eq $board -or -not $board.PSObject.Properties['comparison']) { Write-Output ('BLIND: ' + (Split-Path $BoardFile -Leaf) + ' carries no comparison'); Exit-Guard -Name 'audit-ended-window' -Summary 'no comparison' -Code 3 }
$nowS = if ($Now) { $Now } else { (Get-Date).ToString('yyyy-MM-dd') }
$dated = 0
foreach ($r in @($board.comparison)) { foreach ($s in @($r.stores)) { if ([string]$s.ad_to -match '^\d{4}-\d{2}-\d{2}$') { $dated++ } } }
$cells = @(Get-EndedWindowCells $board $nowS)
$n = $cells.Count
if ($n -eq 0) {
  Write-Output ('ended windows: none of the ' + $dated + ' windowed cell(s) on ' + (Split-Path $BoardFile -Leaf) + ' ended before ' + $nowS)
  Exit-Guard -Name 'audit-ended-window' -Summary ('cells=0 windowed=' + $dated) -Code 0
}
foreach ($c in $cells) { Write-Output ('  ENDED WINDOW STILL PRICED: ' + $c.id + ' / ' + $c.store + ' [' + $c.type + '] window ended ' + $c.ad_to + $(if ($c.basis) { ' (' + $c.basis + ')' } else { '' }) + $(if ($c.crown) { ' - holds the crown' } else { '' })) }
foreach ($c in $cells) { Write-Output ('QUARANTINE-CELL ' + $c.id + '|' + $c.store + '|value') }
Write-Output ('QUARANTINE-SCOPE complete cells=' + $n + ' stores=0')
Exit-Guard -Name 'audit-ended-window' -Summary ('cells=' + $n + ' windowed=' + $dated) -Code 2
