<#
  factor-fixture-lib.ps1 - picks the target for test-guards' factor-mismatch case (guard 4 of guards.ps1).

  WHY THIS EXISTS (2026-09-28, queue 2026-09-27-69b343). The case used to halve one hard-coded link,
  white-vinegar / Sam's Club, and assert guard 4's own "x factor white-vinegar" text. Guard 4 grades EVERYDAY
  cells only (a weekly-ad price legitimately differs from its link). From the 2026-09-23 board on, 46 of 321
  Sam's cells, white-vinegar among them, came out typed `sale` (ad_basis ttl), so the mutation landed on a cell
  guard 4 skips by design: tile-integrity failed instead, and the weekly suite read red for a reason that said
  nothing about guard 4. The guard itself still fired on a 2x everyday cell.

  So the target is chosen from the board guards will read: white-vinegar / Sam's (the founding 2-pack) while it
  is an everyday cell, else the first unpinned, unquarantined everyday cell whose link agrees with the board
  (within 2%) and whose size is "<number> <unit>". Its size is halved, and the mutation is PROVED to form a
  >= 1.5x mismatch with the same pu-lib arithmetic guard 4 uses. No such cell returns $null, and the caller
  FAILS loudly: a target set that resolves to nothing is a result, never a silent no-op (the old `if ($target)`
  was one). The caller still asserts guard 4's own text, pinned to the chosen id AND store.
#>
. (Join-Path $PSScriptRoot 'pu-lib.ps1')   # Get-LinkPerUnit: the arithmetic guard 4 grades with
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile

function Find-FactorFixtureTarget {
  param([string]$Root, $Items)
  # the SAME board guards.ps1 reads (its line: newest out\comparison-*.json by name)
  $boardF = (Get-ChildItem (Join-Path $Root 'out\comparison-*.json') | Sort-Object Name -Desc | Select-Object -First 1).FullName
  if (-not $boardF) { return $null }
  $board = Read-JsonFile $boardF
  # a pinned cell is graded at its pin, not its per_unit, so it is not a clean target
  $pins = @{}
  $pinF = Join-Path $Root 'board-price-overrides.json'
  if (Test-Path $pinF) { foreach ($x in @((Read-JsonFile $pinF).cells)) { if ($null -ne $x) { $pins[([string]$x.id + '|' + [string]$x.store)] = 1 } } }
  $first = $null
  foreach ($row in $board.comparison) {
    $lk = $Items.($row.id)
    if (-not $lk) { continue }
    foreach ($s in $row.stores) {
      if (([string]$s.type) -ne 'everyday') { continue }
      if ($pins.ContainsKey([string]$row.id + '|' + [string]$s.store)) { continue }
      $qp = $s.PSObject.Properties['quarantine']; if ($qp -and $qp.Value) { continue }
      $e = $lk.($s.store); if (-not $e -or -not $e.price) { continue }
      $sm = [regex]::Match(([string]$e.size).Trim(), '^([0-9]+(?:\.[0-9]+)?)\s+([a-z. ]+)$')
      if (-not $sm.Success) { continue }
      $sp = 0.0; [void][double]::TryParse((([string]$e.price) -replace '[^0-9.]',''), [ref]$sp)
      $bpu = [double]$s.per_unit
      $lpu = Get-LinkPerUnit -size ([string]$e.size) -unit ([string]$row.unit) -price $sp -name ([string]$e.name)
      if ($null -eq $lpu -or $bpu -le 0 -or [math]::Abs(($lpu / $bpu) - 1) -gt 0.02) { continue }
      $half = ([double]$sm.Groups[1].Value / 2).ToString([Globalization.CultureInfo]::InvariantCulture) + ' ' + $sm.Groups[2].Value
      $mpu = Get-LinkPerUnit -size $half -unit ([string]$row.unit) -price $sp -name ([string]$e.name)
      if ($null -eq $mpu -or ($mpu / $bpu) -lt 1.5) { continue }
      $t = [pscustomobject]@{ id = [string]$row.id; store = [string]$s.store; link = $e; from = [string]$e.size; to = $half; ratio = $mpu / $bpu }
      if ($t.id -eq 'white-vinegar' -and $t.store -eq "Sam's Club") { return $t }
      if (-not $first) { $first = $t }
    }
  }
  return $first
}
