<#
  repair-multipack-sizes.ps1 - fix a size that records ONE unit of a pack the name already counted.

  WHY IT EXISTS. Guard 5 hard-fails a row whose NAME declares a pack and whose SIZE is one unit of it,
  because taken at face value that row publishes a per-unit price at Nx the truth. The gate is right to
  fail closed, but for a subset of those rows nothing is actually unknown: the store told us the count AND
  the per-unit weight in the product name, and only the multiplication is missing. Founding case, and the
  reason this exists - Family Fare's own API returned size "50.5 oz" for
  "Heinz Tomato Ketchup, 2 Pack 50.5 Oz" at $14.99. At face value $0.2968/oz, nearly 2x every other Heinz
  on that same shelf; as 101 oz, $0.1484/oz, exactly where a bulk 2-pack belongs. It turned the nightly
  publish red on 2026-08-01 and there was no way to clear it except an allowlist entry that would have been
  a LIE - the allowlist means "a human checked and the size really is the pack total", and here it is not.

  THE ARITHMETIC LIVES IN multipack-lib.ps1, shared with guards.ps1 and build-walmart-deals.ps1. The
  guard's verdict and this repair must never be able to disagree about what a pack is; two hand-maintained
  copies of one rule is the trap this repo already paid for with pu-lib.

  IT REPAIRS ONLY WHAT THE NAME PROVES. A name with a pack count and NO per-unit weight ("ReaLemon 100%
  Lemon Juice (2 pk)", size "48 fl oz" - the bug guard 5 was built for) is REFUSED and stays a hard fail
  for a human, because inventing a total there is guessing at the exact point the guard exists to stop
  guessing. Two pack counts in one name are refused for the same reason: the total is ambiguous between
  N, M and NxM, and confirming a size against all three is not the same act as choosing one to write.

  DRY RUN by default. -Apply rewrites the size in place and stamps `size_repaired` on the row so the change
  is visible to anything that reads it afterwards, rather than looking like the store's own number.

  Usage:
    .\repair-multipack-sizes.ps1
    .\repair-multipack-sizes.ps1 -Apply
    .\repair-multipack-sizes.ps1 -SelfTest
#>
param(
  [switch]$Apply,
  [string]$RegularDir = '',
  [string]$Root = '',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path } }
if (-not $RegularDir) { $RegularDir = Join-Path $Root 'out\regular' }
. (Join-Path $Root 'multipack-lib.ps1')

if ($SelfTest) {
  $f = 0; $p = 0
  function T($cond, $msg) { if ($cond) { Write-Output ('  PASS  ' + $msg); $script:p++ } else { Write-Output ('  FAIL  ' + $msg); $script:f++ } }
  Write-Output 'repair-multipack-sizes -SelfTest'
  # MUST FIRE: the founding row. Name states 2 packs of 50.5 oz, size records one bottle.
  T ((Get-MpRepairedSize 'Heinz Tomato Ketchup, 2 Pack 50.5 Oz' '50.5 oz') -eq '2 pk 50.5 oz') 'the founding Heinz row repairs to the pack total'
  # MUST REFUSE: guard 5's own founding bug. A pack count with NO per-unit weight cannot be multiplied.
  T ((Get-MpRepairedSize 'ReaLemon 100% Lemon Juice (2 pk)' '48 fl oz') -eq '') 'a pack count with no per-unit weight is REFUSED, not invented'
  # MUST REFUSE: two counts in one name - the total is ambiguous between 2, 6 and 12.
  T ((Get-MpRepairedSize '(2 pack) Pearls Sliced Olives, 6 Pack of 6.5 oz Cans' '6.5 oz') -eq '') 'two pack counts in one name is ambiguous and REFUSED'
  # MUST REFUSE: the size is not the per-unit weight the name states, so we do not know what it is.
  T ((Get-MpRepairedSize 'Something, 2 Pack 50.5 Oz' '12 oz') -eq '') 'a size that is not the name''s per-unit weight is REFUSED'
  # MUST REFUSE: unit families must agree - a name in oz against a size in fl oz is not the same quantity.
  T ((Get-MpRepairedSize 'Juice, 2 Pack 50.5 Oz' '50.5 fl oz') -eq '') 'a unit-family mismatch between name and size is REFUSED'
  # MUST NOT TOUCH a correct row: the size already IS the pack total.
  T ((Get-MpRepairedSize '(12 pack) Great Value Great Northern Beans, 15.5 oz' '186.4 oz') -eq '') 'a size that is already the pack total is left alone'
  # THE REPAIR MUST SATISFY THE GUARD, or it is decoration. Round-trip through the shared classifier.
  $rep = Get-MpRepairedSize 'Heinz Tomato Ketchup, 2 Pack 50.5 Oz' '50.5 oz'
  T ((Test-MpClassify 'Family Fare' 'Heinz Tomato Ketchup, 2 Pack 50.5 Oz' '50.5 oz' @()) -eq 'reject') 'the unrepaired row is still a guard-5 reject'
  T ((Test-MpClassify 'Family Fare' 'Heinz Tomato Ketchup, 2 Pack 50.5 Oz' $rep @()) -ne 'reject') 'the REPAIRED row passes the same guard that rejected it'
  if ($f -gt 0) { Write-Output ('repair-multipack-sizes SELFTEST: ' + $f + ' FAILED'); exit 2 }
  Write-Output ('repair-multipack-sizes SELFTEST: all ' + $p + ' passed')
  exit 0
}

if (-not (Test-Path $RegularDir)) { Write-Output ('repair-multipack-sizes: BLIND - no regular dir at ' + $RegularDir); exit 3 }
$allFiles = @(Get-ChildItem (Join-Path $RegularDir '*-regular-*.json') -ErrorAction SilentlyContinue | Sort-Object Name)
if ($allFiles.Count -eq 0) { Write-Output ('repair-multipack-sizes: BLIND - no *-regular-*.json in ' + $RegularDir); exit 3 }

# ---- REPAIR WHAT THE BOARD CAN ACTUALLY READ (2026-08-22) ---------------------------------------------
# This walked EVERY *-regular-*.json in the folder - 170 files, 385 MB - on every run, and today's answer
# was "0 repairable, 0 REFUSED" after 38-58 s on the SHIP path, i.e. time spent before the day's prices go
# live. The engine only ever prices from Select-RegularFileSet (the union window, currently 30 of those
# 170 files); a pack size in a file outside that window cannot reach the board, so repairing it changes
# nothing a reader will ever see.
# NOTHING IS LEFT UNREPAIRED BY THIS. Files only age OUT of the union, never into it: a capture is written
# fresh, enters the window immediately, and is walked by every run until it expires. So each file is still
# repaired on every day it can influence a price.
# ONE SOURCE FOR THE WINDOW, deliberately - the same function compare-deals and guards use. A private copy
# here is exactly how this file could start repairing a different set than the board prices from, which is
# the drift class the union self-test in compare-deals exists to catch.
$files = $allFiles
try {
  . (Join-Path $Root 'regular-fileset-lib.ps1')
  $asOfMp = (Get-Date).Date
  $sel = @(Select-RegularFileSet $allFiles $asOfMp (Get-RegularUnionDays))
  if ($sel.Count -gt 0) { $files = @($sel | Sort-Object Name) }
  else { Write-Output '  note: the engine file set came back EMPTY - repairing every capture instead, because a repair that examines nothing is worse than a slow one' }
} catch {
  # Fail OPEN to the old behaviour: a repair that silently examined a SMALLER set than it reported would
  # be the confident-ok-over-an-empty-examination shape this estate keeps rediscovering.
  Write-Output ('  note: could not resolve the engine file set (' + $_.Exception.Message + ') - repairing every capture')
}
Write-Output ('repair-multipack-sizes: examining ' + $files.Count + ' of ' + $allFiles.Count + ' capture file(s) - the ones inside the engine union window')

$allow = Get-MpAllowKeys $Root
$repaired = 0; $refused = 0; $examined = 0
$refusedRows = New-Object 'System.Collections.Generic.List[string]'
foreach ($file in $files) {
  $raw = ((Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8) + '').Trim()
  if ($raw -eq '') { Write-Output ('  SKIP ' + $file.Name + ' - empty on disk (unreadable, not "no rows")'); continue }
  $doc = $raw | ConvertFrom-Json
  if ($null -eq $doc) { Write-Output ('  SKIP ' + $file.Name + ' - parsed to null'); continue }
  $touched = 0
  foreach ($d in @($doc.deals)) {
    if ($null -eq $d) { continue }
    $name = [string]$d.item; $size = [string]$d.size
    if ((Test-MpClassify ([string]$doc.store) $name $size $allow) -ne 'reject') { continue }
    $examined++
    $fix = Get-MpRepairedSize $name $size
    if ($fix -eq '') {
      $refused++
      $refusedRows.Add(('  REFUSED [' + [string]$doc.store + '] ''' + $name + ''' size=[' + $size + '] - the name does not state a per-unit weight to multiply. This stays a HARD FAIL for a human (multipack-allowlist.json).'))
      continue
    }
    Write-Output ('  REPAIR  [' + [string]$doc.store + '] ''' + $name + '''  size [' + $size + '] -> [' + $fix + ']')
    if ($Apply) {
      $d.size = $fix
      if ($d.PSObject.Properties['size_repaired']) { $d.size_repaired = $size } else { $d | Add-Member -NotePropertyName size_repaired -NotePropertyValue $size -Force }
      $touched++
    }
    $repaired++
  }
  if ($Apply -and $touched -gt 0) {
    ($doc | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $file.FullName -Encoding UTF8
    Write-Output ('  wrote ' + $file.Name + ' (' + $touched + ' size(s) repaired)')
  }
}
foreach ($r in $refusedRows) { Write-Output $r }
Write-Output ('repair-multipack-sizes: ' + $files.Count + ' file(s), ' + $examined + ' guard-5 reject(s) examined, ' +
  $repaired + ' repairable, ' + $refused + ' REFUSED (need a human)' + $(if ($Apply) { ' - APPLIED' } else { ' - dry run, pass -Apply to write' }))
exit 0
