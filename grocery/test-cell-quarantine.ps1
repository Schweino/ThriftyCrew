<#
  test-cell-quarantine.ps1 -SelfTest - the frozen fixtures for grocery\cell-quarantine-lib.ps1: a bad cell quarantines
  itself, a bad store drops itself, and only a board-scoped failure or the circuit breaker holds the board (Brad,
  2026-09-21). Hermetic: every board here is built in memory, so run-gates runs it on every push.

  THE ASSERTION THAT MATTERS is never "guards said something". Every MUST FIRE for a quarantine asserts the cell is
  HELD AT ITS LAST VERIFIED VALUE (or absent) AND DOES NOT CARRY THE BAD VALUE, and the CLEAN TWIN asserts every other
  cell of the same board is unchanged, value by value. A test that only checked the verdict would stay green while the
  bad price shipped - the shape of the 21 guard-blindness incidents in memory guard-blindness-family.

  The breaker cases sit EXACTLY at each bar and one cell past it, on integers (cells x 100 against priced x bar), so no
  double decides them (.claude\rules\ops-and-gates.md). The founding case is frozen from the real 2026-09-21 rows:
  vegetable-oil / Sam's Club on comparison-2026-09-21.json and on public\board.json at origin/main aa53973d5.
#>
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'cell-quarantine-lib.ps1')
if (-not $SelfTest) { Write-Output 'usage: test-cell-quarantine.ps1 -SelfTest'; exit 0 }

$script:qPass = 0; $script:qFail = 0; $script:qCases = 0
function Assert-QCase([string]$Label, [scriptblock]$Check) {
  $script:qCases++
  $ok = $false; $err = ''
  try { $ok = [bool](& $Check) } catch { $err = $_.Exception.Message }
  if ($ok) { $script:qPass++; Write-Output ('  PASS  ' + $Label) }
  else { $script:qFail++; Write-Output ('  FAIL  ' + $Label + $(if ($err) { '  [threw: ' + $err + ']' } else { '' })) }
}

function New-QBoard([string[]]$Stores, [int]$Commodities, [int]$MaxAge = 90, [hashtable]$OnlyFirst = @{}) {
  # Every cell priced, deterministic per-units. $OnlyFirst[store] = N prices that store on the first N rows only.
  $rows = @()
  for ($i = 1; $i -le $Commodities; $i++) {
    $cells = @(); $j = 0
    foreach ($st in $Stores) {
      $j++
      if ($OnlyFirst.ContainsKey($st) -and $i -gt [int]$OnlyFirst[$st]) { continue }
      $cells += [pscustomobject]@{ store = $st; per_unit = [math]::Round(1 + $i * 0.01 + $j * 0.1, 4); unit = 'oz'; type = 'everyday'; bulk = $false; membership = $false; member_label = ''; item = ('Item ' + $i + ' at ' + $st); ad = '$1.00'; size = '16 oz'; basis = 'size 16 oz'; note = ''; source_ad = 'everyday shelf price'; ad_from = ''; ad_to = ''; ad_basis = ''; as_of = '2026-09-21' }
    }
    $rows += [pscustomobject]@{ commodity = ('C' + $i); id = ('c' + $i); unit = 'oz'; cheapest_store = ''; cheapest_price = 0.0; cheapest_type = ''; nomem_store = ''; nomem_price = 0.0; nomem_type = ''; stores = @($cells) }
  }
  $b = [pscustomobject]@{ week_of = '2026-09-21'; max_publish_age_days = $MaxAge; comparison = @($rows) }
  foreach ($r in $b.comparison) { Update-TcRowWinners $r }
  return $b
}
function Get-QCell($Board, [string]$Id, [string]$Store) {
  foreach ($r in @($Board.comparison)) { if ([string]$r.id -eq $Id) { foreach ($s in @($r.stores)) { if ([string]$s.store -eq $Store) { return $s } } } }
  return $null
}
function Get-QSnapshot($Board) {
  $m = @{}; foreach ($r in @($Board.comparison)) { foreach ($s in @($r.stores)) { $m[[string]$r.id + '|' + [string]$s.store] = ([string]$s.per_unit + '|' + [string]$s.item) } }
  return $m
}
function New-QLastPublished([string[]]$Stores, [string]$RowsJson, [string]$Date) {
  $doc = ('{"__meta":{"stores":' + (ConvertTo-Json @($Stores) -Compress) + '},"__rows":' + $RowsJson + '}') | ConvertFrom-Json
  $lpc = Get-TcLastPublishedCells -BoardDoc $doc -PublishedDate $Date
  return [pscustomobject]@{ cells = $lpc.cells; n = $lpc.n; source = 'fixture'; commit = ''; date = $Date }
}
function New-QFail([string]$Id, [string]$Store, [string]$Kind = 'value', $BadPu = $null) {
  return (New-TcGuardFailure -Message ('HARD FAIL: fixture ' + $Id + ' / ' + $Store) -Family 'cell' -Id $Id -Store $Store -Kind $Kind -BadPerUnit $BadPu -Check 'fixture')
}
function ConvertTo-QPlan($Disposition) {
  # the same shape Write-TcQuarantinePlan writes and apply-cell-quarantine reads back through JSON
  $p = [ordered]@{ action = $Disposition.action; cells = @(@($Disposition.cells) | ForEach-Object { [ordered]@{ id = $_.id; store = $_.store; kind = $_.kind; bad_per_unit = $_.bad_per_unit; bad_item = $_.bad_item; reasons = @($_.reasons) } }); stores = @(@($Disposition.stores) | ForEach-Object { [ordered]@{ store = $_.store; reasons = @($_.reasons) } }) }
  return (($p | ConvertTo-Json -Depth 8) | ConvertFrom-Json)
}
function Invoke-QRoundTrip($Board) { return (($Board | ConvertTo-Json -Depth 12) | ConvertFrom-Json) }

$S5 = @('A', 'B', 'C', 'D', 'E')
Write-Output 'test-cell-quarantine: per-cell quarantine, store drop, board hold and the circuit breaker'

# ---- 1-4: the core path, on one 100-cell board (5 stores x 20 commodities) ----------------------------------------
$b1 = New-QBoard -Stores $S5 -Commodities 20
$snap1 = Get-QSnapshot $b1
$bad3 = [double](Get-QCell $b1 'c3' 'B').per_unit
$lp1 = New-QLastPublished -Stores $S5 -Date '2026-09-20' -RowsJson '{"c3":{"u":"oz","p":[[1,0.95,0,"x"]],"x":[]}}'
$d1 = Get-TcGuardsDisposition -Failures @((New-QFail 'c3' 'B' 'value' $bad3), (New-QFail 'c4' 'C')) -Board $b1
Assert-QCase 'MUST FIRE  two cell-scoped failures under the breaker ask for a QUARANTINE of exactly those two cells (exit 2 until applied)' {
  $d1.action -eq 'quarantine' -and @($d1.cells).Count -eq 2 -and ((@($d1.cells) | ForEach-Object { $_.id + '|' + $_.store }) -join ',') -eq 'c3|B,c4|C' -and (Get-TcGuardsExitCode $d1.action) -eq 2 }
$a1 = Invoke-TcCellQuarantine -Board $b1 -Plan (ConvertTo-QPlan $d1) -LastPublished $lp1 -Today '2026-09-21' -MaxAgeDays 90
$c3 = Get-QCell $b1 'c3' 'B'
Assert-QCase 'MUST FIRE  a quarantined cell publishes its LAST VERIFIED value (0.95) with that value''s date (2026-09-20), and NOT the bad value' {
  $a1.ok -and $null -ne $c3 -and [double]$c3.per_unit -eq 0.95 -and [string]$c3.quarantine.since -eq '2026-09-20' -and [math]::Abs([double]$c3.per_unit - $bad3) -gt 0.0001 -and (Test-TcCellQuarantined $c3) }
Assert-QCase 'MUST FIRE  a cell with NO previously published value is WITHHELD - absent from the board, never invented' {
  $null -eq (Get-QCell $b1 'c4' 'C') -and @(@($a1.cells) | Where-Object { $_.id -eq 'c4' -and $_.action -eq 'withheld' }).Count -eq 1 }
Assert-QCase 'CLEAN TWIN every OTHER cell of the quarantined board publishes unchanged (98 of 98 cells, value and product)' {
  $after = Get-QSnapshot $b1; $same = 0
  foreach ($k in $snap1.Keys) { if ($k -eq 'c3|B' -or $k -eq 'c4|C') { continue }; if ($after.ContainsKey($k) -and $after[$k] -eq $snap1[$k]) { $same++ } }
  $same -eq 98 }
$b1rt = Invoke-QRoundTrip $b1
$d1b = Get-TcGuardsDisposition -Failures @((New-QFail 'c3' 'B' 'value' $bad3), (New-QFail 'c4' 'C')) -Board $b1rt
Assert-QCase 'MUST FIRE  the SECOND run over the applied board (through JSON, as on disk) is QUARANTINED, exit 4, the block verified' {
  $d1b.action -eq 'quarantined' -and (Get-TcGuardsExitCode $d1b.action) -eq 4 -and $d1b.block.ok }
Assert-QCase 'CLEAN TWIN the second run prints GUARDS QUARANTINED naming the held cell and its date' {
  $vl = Get-TcGuardsVerdictLines -Disposition $d1b -FailCount 2
  $vl.code -eq 4 -and ($vl.lines -join "`n") -match 'QUARANTINED  c3 / B  held at 0\.95 \(last verified published 2026-09-20\)' -and $vl.lines[-1].StartsWith('GUARDS QUARANTINED: 1 cell(s) held') }
$b1t = Invoke-QRoundTrip $b1; (Get-QCell $b1t 'c3' 'B').per_unit = $bad3
Assert-QCase 'MUST FIRE  a held cell carrying the BAD value again (tampered after the apply) HOLDS the board' {
  (Get-TcGuardsDisposition -Failures @((New-QFail 'c3' 'B' 'value' $bad3)) -Board $b1t).action -eq 'hold' }
Assert-QCase 'MUST FIRE  a VALUE finding on the second run whose number IS the held price (0.95) HOLDS - the last verified price is condemned too' {
  (Get-TcGuardsDisposition -Failures @((New-QFail 'c3' 'B' 'value' 0.95)) -Board (Invoke-QRoundTrip $b1)).action -eq 'hold' }
Assert-QCase 'CLEAN TWIN a SELECTION finding at the held price stays covered - censorship does not condemn the number shown' {
  (Get-TcGuardsDisposition -Failures @((New-QFail 'c3' 'B' 'selection' 0.95), (New-QFail 'c4' 'C')) -Board (Invoke-QRoundTrip $b1)).action -eq 'quarantined' }
Assert-QCase 'MUST FIRE  a NEW cell failure on a board that is already quarantined HOLDS (a quarantine is applied once per build)' {
  (Get-TcGuardsDisposition -Failures @((New-QFail 'c3' 'B'), (New-QFail 'c9' 'D')) -Board (Invoke-QRoundTrip $b1)).action -eq 'hold' }

# ---- 5-6: board-scoped holds, a clean board passes -----------------------------------------------------------------
$b2 = New-QBoard -Stores $S5 -Commodities 20
$d2 = Get-TcGuardsDisposition -Failures @((New-QFail 'c3' 'B'), (New-TcGuardFailure -Message 'HARD FAIL: pu-lib per-unit math regressed' -Family 'board')) -Board $b2
Assert-QCase 'MUST FIRE  a board-scoped failure HOLDS the board even beside a quarantinable cell (exit 2, GUARDS FAILED)' {
  $d2.action -eq 'hold' -and (Get-TcGuardsExitCode $d2.action) -eq 2 -and (Get-TcGuardsVerdictLines -Disposition $d2 -FailCount 2).lines[-1] -eq 'GUARDS FAILED: 2 hard invariant(s) violated. Board NOT safe to publish.' }
$d2u = (ConvertTo-TcGuardFailures -Messages @('HARD FAIL: an unscoped guard') -Scoped @()).failures
Assert-QCase 'MUST FIRE  a failure no guard scoped is BOARD family and holds, exactly as before this change' {
  @($d2u).Count -eq 1 -and $d2u[0].family -eq 'board' -and (Get-TcGuardsDisposition -Failures $d2u -Board $b2).action -eq 'hold' }
Assert-QCase 'MUST FIRE  a cell failure naming a cell the board does not price cannot be scoped, so it HOLDS' {
  (Get-TcGuardsDisposition -Failures @((New-QFail 'no-such-id' 'B')) -Board $b2).action -eq 'hold' }
$d0 = Get-TcGuardsDisposition -Failures @() -Board $b2
Assert-QCase 'MUST NOT FIRE a clean board quarantines nothing: pass, exit 0, the old GUARDS OK line byte for byte' {
  $d0.action -eq 'pass' -and @($d0.cells).Count -eq 0 -and (Get-TcGuardsExitCode $d0.action) -eq 0 -and (Get-TcGuardsVerdictLines -Disposition $d0 -FailCount 0).lines[-1] -eq 'GUARDS OK: every hard invariant holds. Safe to publish.' -and $null -eq (Get-TcQuarantineBlock $b2) }

# ---- 7-8: THE CIRCUIT BREAKER, at each bar and one cell past it ---------------------------------------------------
# Board bar 2%: 100 priced cells, 2 quarantined in two stores (1 of 20 = 5% each, under the store bar) is 2 x 100 = 200
# against 100 x 2 = 200 - AT the bar, not over it. A third cell is 300 > 200.
$b3 = New-QBoard -Stores $S5 -Commodities 20
Assert-QCase 'AT THE BAR  2 of 100 priced cells (exactly the 2% board bar) still quarantines' {
  (Get-TcGuardsDisposition -Failures @((New-QFail 'c1' 'A'), (New-QFail 'c2' 'B')) -Board $b3).action -eq 'quarantine' }
Assert-QCase 'MUST FIRE  ONE CELL PAST the 2% board bar (3 of 100) trips the breaker and HOLDS' {
  $d = Get-TcGuardsDisposition -Failures @((New-QFail 'c1' 'A'), (New-QFail 'c2' 'B'), (New-QFail 'c3' 'C')) -Board $b3
  $d.action -eq 'hold' -and $d.breaker.tripped -and $d.breaker.why -match 'more than 2% of the board' }
# Store bar 10%: store E prices only 10 rows (110 priced in all). 1 E cell is 100 against 10 x 10 = 100 - AT the bar;
# 2 E cells is 200 > 100, while the board is 2 x 100 = 200 against 110 x 2 = 220, under ITS bar - so only the store trips.
$b4 = New-QBoard -Stores @('A', 'B', 'C', 'D', 'E', 'F') -Commodities 20 -OnlyFirst @{ E = 10 }
Assert-QCase 'AT THE BAR  1 of store E''s 10 priced cells (exactly the 10% store bar) still quarantines' {
  $c = Get-TcBoardPricedCounts $b4
  [int]$c.perStore['E'] -eq 10 -and (Get-TcGuardsDisposition -Failures @((New-QFail 'c1' 'E')) -Board $b4).action -eq 'quarantine' }
Assert-QCase 'MUST FIRE  ONE CELL PAST the 10% store bar (2 of 10 at E, board 2 of 110 under its own bar) HOLDS on the store bar alone' {
  $d = Get-TcGuardsDisposition -Failures @((New-QFail 'c1' 'E'), (New-QFail 'c2' 'E')) -Board $b4
  $d.action -eq 'hold' -and $d.breaker.tripped -and $d.breaker.why -match 'of that store' -and $d.breaker.why -notmatch 'of the board' }

# ---- 9: a store-scoped failure drops only that store's EVERYDAY cells ----------------------------------------------
$b5 = New-QBoard -Stores $S5 -Commodities 20
(Get-QCell $b5 'c7' 'B').type = 'sale'
$snap5 = Get-QSnapshot $b5
$d5 = Get-TcGuardsDisposition -Failures @((New-TcGuardFailure -Message 'HARD FAIL: store data collapsed [b]' -Family 'store' -Store 'B')) -Board $b5
$a5 = Invoke-TcCellQuarantine -Board $b5 -Plan (ConvertTo-QPlan $d5) -LastPublished $null -Today '2026-09-21' -MaxAgeDays 90
Assert-QCase 'MUST FIRE  a store-scoped failure DROPS only that store: its 19 everyday cells go, its live sale cell stays' {
  $d5.action -eq 'quarantine' -and $a5.ok -and @($a5.stores)[0].cells -eq 19 -and $null -ne (Get-QCell $b5 'c7' 'B') -and $null -eq (Get-QCell $b5 'c1' 'B') }
Assert-QCase 'CLEAN TWIN every cell of the other four stores is unchanged after the store drop (80 of 80)' {
  $after = Get-QSnapshot $b5; $same = 0
  foreach ($k in $snap5.Keys) { if ($k.EndsWith('|B')) { continue }; if ($after.ContainsKey($k) -and $after[$k] -eq $snap5[$k]) { $same++ } }
  $same -eq 80 }
Assert-QCase 'MUST FIRE  the second run over the dropped store is QUARANTINED only while the store stays dropped' {
  $rt = Invoke-QRoundTrip $b5
  $ok1 = (Get-TcGuardsDisposition -Failures @() -Board $rt).action -eq 'quarantined'
  $rc1 = @($rt.comparison | Where-Object { $_.id -eq 'c1' })[0]
  $rc1.stores = @(@($rc1.stores) + @([pscustomobject]@{ store = 'B'; per_unit = 1.5; type = 'everyday'; item = 'back again' }))
  $ok1 -and (Get-TcGuardsDisposition -Failures @() -Board $rt).action -eq 'hold' }

# ---- 10-14: what a held cell may show -----------------------------------------------------------------------------
function Invoke-QOne([string]$Kind, $LastRowJson, [string]$LpDate, [string]$Today = '2026-09-21', $BadPu = $null) {
  $b = New-QBoard -Stores $S5 -Commodities 5
  $lp = New-QLastPublished -Stores $S5 -Date $LpDate -RowsJson $LastRowJson
  $d = Get-TcGuardsDisposition -Failures @((New-QFail 'c2' 'B' $Kind $BadPu)) -Board $b
  $a = Invoke-TcCellQuarantine -Board $b -Plan (ConvertTo-QPlan $d) -LastPublished $lp -Today $Today -MaxAgeDays 90
  return [pscustomobject]@{ a = $a; cell = (Get-QCell $b 'c2' 'B'); entry = @($a.cells)[0] }
}
$candB2 = 1.22   # New-QBoard's per-unit for c2 at the 2nd store: 1 + 2 x 0.01 + 2 x 0.1
Assert-QCase 'MUST FIRE  a VALUE finding whose last published value IS the condemned value withholds it, never republishes it' {
  $o = Invoke-QOne 'value' '{"c2":{"u":"oz","p":[[1,1.22,0,"x"]],"x":[]}}' '2026-09-20'
  $o.a.ok -and $null -eq $o.cell -and $o.entry.action -eq 'withheld' -and $o.entry.why -match 'IS the value' }
Assert-QCase 'CLEAN TWIN a SELECTION finding (band censorship) whose last value equals today''s still shows that real price, dated' {
  $o = Invoke-QOne 'selection' '{"c2":{"u":"oz","p":[[1,1.22,0,"x"]],"x":[]}}' '2026-09-20'
  $o.a.ok -and $null -ne $o.cell -and [double]$o.cell.per_unit -eq $candB2 -and [string]$o.cell.quarantine.since -eq '2026-09-20' -and [string]$o.cell.item -eq 'Item 2 at B' }
Assert-QCase 'MUST FIRE  a last published SALE is withheld - the published board carries no end date for it' {
  $o = Invoke-QOne 'value' '{"c2":{"u":"oz","p":[[1,0.99,1,"x"]],"x":[]}}' '2026-09-20'
  $null -eq $o.cell -and $o.entry.why -match 'sale' }
Assert-QCase 'AT THE BAR  a last value exactly 90 days old (the board''s max_publish_age_days) is still shown' {
  $o = Invoke-QOne 'value' '{"c2":{"u":"oz","p":[[1,0.99,0,"x"]],"x":[]}}' '2026-06-23'
  $null -ne $o.cell -and [double]$o.cell.per_unit -eq 0.99 }
Assert-QCase 'MUST FIRE  ONE DAY PAST the publish window (91 days) the last value is withheld' {
  $o = Invoke-QOne 'value' '{"c2":{"u":"oz","p":[[1,0.99,0,"x"]],"x":[]}}' '2026-06-22'
  $null -eq $o.cell -and $o.entry.why -match '91 days old' }
Assert-QCase 'MUST FIRE  a DIFFERENT last value blanks today''s product fields, so no package is paired with a price it does not produce' {
  $o = Invoke-QOne 'value' '{"c2":{"u":"oz","p":[[1,0.99,4,"x"]],"x":[]}}' '2026-09-20'
  [double]$o.cell.per_unit -eq 0.99 -and [string]$o.cell.item -eq '' -and [string]$o.cell.ad -eq '' -and [string]$o.cell.size -eq '' -and [bool]$o.cell.bulk -and $o.cell.quarantine.bad_item -eq 'Item 2 at B' }
Assert-QCase 'MUST FIRE  a CARRIED date (the last board held this cell since 2026-09-15) is kept, not refreshed to the board''s date' {
  $o = Invoke-QOne 'selection' '{"c2":{"u":"oz","p":[[1,0.99,0,"x"]],"x":[],"q":[[1,"2026-09-15"]]}}' '2026-09-20'
  [string]$o.cell.quarantine.since -eq '2026-09-15' }
$b6 = New-QBoard -Stores @('A') -Commodities 3
$d6 = Get-TcGuardsDisposition -Failures @((New-QFail 'c2' 'A')) -Board $b6
Assert-QCase 'MUST FIRE  withholding the ONLY priced cell of a row is REFUSED (recipes cost from that row) - the caller holds' {
  $a6 = Invoke-TcCellQuarantine -Board $b6 -Plan (ConvertTo-QPlan $d6) -LastPublished $null -Today '2026-09-21' -MaxAgeDays 90
  -not $a6.ok -and $a6.refusal -match 'no priced store' }

# ---- 15: the delegated-audit protocol ------------------------------------------------------------------------------
$okLines = @('band-censorship: RATCHET BROKEN', 'QUARANTINE-CELL vegetable-oil|Sam''s Club|selection', 'QUARANTINE-SCOPE complete cells=1 stores=0', 'BAND-CENSORSHIP-COMPLETE x')
Assert-QCase 'MUST FIRE  a child that names its cells and affirms the scope is complete is scoped to them, kind kept' {
  $sc = Get-TcChildQuarantineScope $okLines
  $null -ne $sc -and @($sc.cells).Count -eq 1 -and $sc.cells[0].id -eq 'vegetable-oil' -and $sc.cells[0].store -eq 'Sam''s Club' -and $sc.cells[0].kind -eq 'selection' }
Assert-QCase 'MUST FIRE  a child that names cells but never affirms a complete scope stays BOARD scoped (holds)' {
  $null -eq (Get-TcChildQuarantineScope @('QUARANTINE-CELL a|B|value')) }
Assert-QCase 'MUST FIRE  a scope whose affirmed count disagrees with its lines stays BOARD scoped (a line was lost)' {
  $null -eq (Get-TcChildQuarantineScope @('QUARANTINE-CELL a|B|value', 'QUARANTINE-SCOPE complete cells=2 stores=0')) }
Assert-QCase 'MUST FIRE  a malformed scope line (no store) stays BOARD scoped' {
  $null -eq (Get-TcChildQuarantineScope @('QUARANTINE-CELL onlyanid', 'QUARANTINE-SCOPE complete cells=1')) }

# ---- 16: THE FOUNDING CASE, frozen from the real rows of 2026-09-21 ------------------------------------------------
# comparison-2026-09-21.json (built 08:49:37): vegetable-oil, the 7 priced cells, trimmed to the fields the engine and
# renderers read. public\board.json at origin/main aa53973d5 (committed 2026-09-21): the same row as published at 05:08.
$vegJson = '{"week_of":"2026-09-21","max_publish_age_days":90,"comparison":[{"commodity":"Vegetable / Canola Oil","id":"vegetable-oil","unit":"floz","cheapest_store":"Walmart","cheapest_price":0.0686,"cheapest_type":"everyday","nomem_store":"Walmart","nomem_price":0.0686,"nomem_type":"everyday","stores":[' +
  '{"store":"Walmart","per_unit":0.0686,"type":"everyday","bulk":false,"membership":false,"item":"Great Value Vegetable Oil, Heart Healthy and Versatile, 1 Gallon Bottle","ad":"$8.78","size":"128 fl oz","basis":"size 128 floz","as_of":"2026-09-19"},' +
  '{"store":"Sam''s Club","per_unit":0.0723,"type":"everyday","bulk":true,"membership":true,"item":"Member''s Mark Vegetable Oil, 192 oz.","ad":"$13.88","size":"192 fl oz","basis":"size 192 floz","as_of":"2026-09-21"},' +
  '{"store":"Aldi","per_unit":0.074,"type":"everyday","bulk":false,"membership":false,"item":"Carlini Pure Vegetable Oil","ad":"$3.55","size":"48 fl oz","basis":"size 48 floz","as_of":"2026-08-15"},' +
  '{"store":"Fareway","per_unit":0.0741,"type":"sale","bulk":true,"membership":false,"item":"Fareway Vegetable Oil","ad":"$9.48","size":"128 oz","basis":"size 128 floz","as_of":"2026-09-21"},' +
  '{"store":"Baker''s","per_unit":0.0804,"type":"everyday","bulk":false,"membership":false,"item":"Kroger 100% Pure Vegetable Oil","ad":"$10.29","size":"1 gal","basis":"size 128 floz","as_of":"2026-09-19"},' +
  '{"store":"Hy-Vee","per_unit":0.0873,"type":"sale","bulk":false,"membership":false,"item":"That''s Smart! vegetable or canola oil, 40 fl oz., $3.49","ad":"That''s Smart! vegetable or canola oil, 40 fl oz., $3.49","size":"","basis":"size 40 floz","as_of":""},' +
  '{"store":"Family Fare","per_unit":0.096,"type":"everyday","bulk":false,"membership":false,"item":"Our Family Vegetable Oil, 100% Pure 1 Gal","ad":"$12.29","size":"1 gal","basis":"size 128 floz","as_of":"2026-09-05"}]}]}'
$veg = $vegJson | ConvertFrom-Json
$vegStores = @('Hy-Vee', 'Aldi', 'Family Fare', 'Fareway', 'Baker''s', 'Sam''s Club', 'Walmart')
# 60 synthetic rows at the same seven stores stand in for the rest of the real board (2,705 priced cells), so the
# breaker sees a board rather than one row: 1 of 427 cells, and 1 of Sam's 61, both far under their bars.
$vegFiller = New-QBoard -Stores $vegStores -Commodities 60
$veg.comparison = @(@($veg.comparison) + @($vegFiller.comparison))
$vegLp = New-QLastPublished -Stores $vegStores -Date '2026-09-21' -RowsJson '{"vegetable-oil":{"u":"floz","p":[[6,0.0686,0,"7c/fl oz"],[5,0.0723,2,"7c/fl oz"],[1,0.074,0,"7c/fl oz"],[4,0.0804,0,"8c/fl oz"],[0,0.0933,0,"9c/fl oz"],[2,0.096,0,"10c/fl oz"]],"x":[[3,0]]}}'
$vegScope = Get-TcChildQuarantineScope $okLines
$vegFail = @($vegScope.cells | ForEach-Object { New-TcGuardFailure -Message 'HARD FAIL: no NEW cell publishes a dearer price because the band refused a near-floor row that was cheaper (RATCHET against out\band-censorship-baseline.json, may only go down) (see audit-band-censorship.ps1)' -Family 'cell' -Id $_.id -Store $_.store -Kind $_.kind -Check 'band-censorship' })
$vegD = Get-TcGuardsDisposition -Failures $vegFail -Board $veg
$vegA = Invoke-TcCellQuarantine -Board $veg -Plan (ConvertTo-QPlan $vegD) -LastPublished $vegLp -Today '2026-09-21' -MaxAgeDays 90
$vegSams = Get-QCell $veg 'vegetable-oil' 'Sam''s Club'
Assert-QCase 'MUST FIRE  FOUNDING CASE vegetable-oil / Sam''s Club (band censorship, 2026-09-21) is quarantined, not the board: held at 0.0723 dated 2026-09-21' {
  $vegD.action -eq 'quarantine' -and $vegA.ok -and [double]$vegSams.per_unit -eq 0.0723 -and [string]$vegSams.quarantine.since -eq '2026-09-21' -and (Test-TcCellQuarantined $vegSams) }
Assert-QCase 'CLEAN TWIN FOUNDING CASE the other six vegetable-oil cells publish unchanged, and Walmart still wins the row at 0.0686' {
  $row = $veg.comparison[0]; $n = 0
  foreach ($s in @($row.stores)) { if ($s.store -ne 'Sam''s Club' -and -not (Test-TcCellQuarantined $s)) { $n++ } }
  $n -eq 6 -and $row.cheapest_store -eq 'Walmart' -and [double]$row.cheapest_price -eq 0.0686 -and [double](Get-QCell $veg 'vegetable-oil' 'Walmart').per_unit -eq 0.0686 }
Assert-QCase 'MUST FIRE  FOUNDING CASE the second run over the quarantined row (through JSON) exits 4, not 0 and not 2' {
  (Get-TcGuardsExitCode (Get-TcGuardsDisposition -Failures $vegFail -Board (Invoke-QRoundTrip $veg)).action) -eq 4 }

# ---- 17: the wiring - guards.ps1 decides through this library, and the source ratchet left the gate -----------------
$gSrc = [IO.File]::ReadAllText((Join-Path $root 'guards.ps1'))
$needleDisp = 'Get-TcGuards' + 'Disposition -Failures'
$needleExit = '-Code $gv' + '.code'
$needleJr = "Register-Kid 'json-" + "readers'"
Assert-QCase 'MUST FIRE  guards.ps1 exits with the disposition''s code and no longer runs the json-readers source ratchet' {
  $gSrc.Contains($needleDisp) -and $gSrc.Contains($needleExit) -and -not $gSrc.Contains($needleJr) }

# ---- 18: a quarantined cell's link follows the held value, in the quarantine step itself (2026-09-22) ---------------
# Frozen from the first all-derived board of 2026-09-22: lotion | Walmart held at 0.2175 while product-urls.json still
# linked the condemned Queen Helene row (0.1244), so audit-tile-integrity refused the hold until a second prune ran.
function New-QLinks {
  return ('{"lotion":{"commodity":"lotion",' +
    '"Walmart":{"url":"https://www.walmart.com/ip/queen-helene","name":"Queen Helene Cocoa Butter Hand & Body Lotion for Dry Skin, 32 oz","price":3.98,"size":"32 oz"},' +
    '"Baker''s":{"url":"https://www.bakersplus.com/p/kroger-cocoa-butter-lotion/0004126002319","name":"Kroger Cocoa Butter Lotion","price":4.19,"size":"20.3 fl oz"},' +
    '"Aldi":{"url":"https://www.aldi.us/lacura","name":"Lacura Body Lotion 18 OZ","price":"$3.99","size":"18 fl oz"}}}') | ConvertFrom-Json
}
$qPub = ('{"lotion":{"commodity":"lotion","Walmart":{"url":"https://www.walmart.com/ip/equate-ultra","name":"Equate Ultra Moisturizing Extra Dry Skin Lotion, 32 oz","price":6.96,"size":"32 fl oz"}}}') | ConvertFrom-Json
$qHeld = [pscustomobject]@{ id = 'lotion'; store = 'Walmart'; action = 'last-good'; per_unit = 0.2175; bad_per_unit = 0.1244 }
$qL1 = New-QLinks; $qC1 = Update-TcQuarantineLinks -Items $qL1 -Entries @($qHeld) -PublishedItems $qPub
Assert-QCase 'MUST FIRE  FOUNDING CASE lotion | Walmart held at 0.2175: its link leaves the condemned Queen Helene row for the link the published board was built with' {
  $qL1.lotion.Walmart.url -eq 'https://www.walmart.com/ip/equate-ultra' -and @($qC1).Count -eq 1 -and $qC1[0].action -eq 'restored-published-link' }
Assert-QCase 'CLEAN TWIN  the cells nobody quarantined keep their links exactly (Baker''s and Aldi)' {
  $qL1.lotion.'Baker''s'.url -eq 'https://www.bakersplus.com/p/kroger-cocoa-butter-lotion/0004126002319' -and $qL1.lotion.Aldi.url -eq 'https://www.aldi.us/lacura' }
$qL2 = New-QLinks; $qC2 = Update-TcQuarantineLinks -Items $qL2 -Entries @([pscustomobject]@{ id = 'lotion'; store = 'Walmart'; action = 'withheld'; per_unit = $null; bad_per_unit = 0.1244 }) -PublishedItems $qPub
Assert-QCase 'MUST FIRE  a WITHHELD cell shows nothing, so its link is removed' {
  -not $qL2.lotion.PSObject.Properties['Walmart'] -and @($qC2).Count -eq 1 -and $qC2[0].action -eq 'removed-link' }
$qL3 = New-QLinks; $qC3 = Update-TcQuarantineLinks -Items $qL3 -Entries @($qHeld) -PublishedItems $null
Assert-QCase 'MUST FIRE  a held cell whose published board linked nothing there loses today''s link rather than keep the condemned one' {
  -not $qL3.lotion.PSObject.Properties['Walmart'] }
$qL4 = New-QLinks; $qC4 = Update-TcQuarantineLinks -Items $qL4 -Entries @([pscustomobject]@{ id = 'lotion'; store = 'Walmart'; action = 'last-good'; per_unit = 0.1244; bad_per_unit = 0.1244 }) -PublishedItems $qPub
Assert-QCase 'MUST NOT FIRE  a cell held at the SAME value kept its row, so its link is left as it was' {
  @($qC4).Count -eq 0 -and $qL4.lotion.Walmart.url -eq 'https://www.walmart.com/ip/queen-helene' }
$acqSrc = [IO.File]::ReadAllText((Join-Path $root 'apply-cell-quarantine.ps1'))
Assert-QCase 'MUST FIRE  apply-cell-quarantine.ps1 moves the links in the same step, after writing the board' {
  $acqSrc.Contains('Update-TcQuarantine' + 'Links -Items') -and $acqSrc.IndexOf('Update-TcQuarantine' + 'Links -Items') -gt $acqSrc.IndexOf('Set-Content -LiteralPath $board' + 'F') }

if ($script:qFail -gt 0) { Write-Output ("test-cell-quarantine self-test: FAIL ({0} of {1} case(s) failed)" -f $script:qFail, $script:qCases); exit 1 }
Write-Output ("test-cell-quarantine self-test: PASS ({0} of {0} case(s))" -f $script:qCases)
exit 0
