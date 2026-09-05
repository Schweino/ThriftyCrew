<#
  verify-no-regression.ps1 - assert that a rule change ONLY ADDED, and changed nothing that already worked.

  WHY: widening a commodity's include is the most dangerous edit in this repo. Matching is FIRST-MATCH-WINS by
  array order, so a looser rule in an earlier commodity silently STEALS products from a later one - and the
  theft looks like success (the thief gains a cell, the victim just quietly has one fewer). On 2026-07-16 a bare
  "chicken breasts?" rule stole a rotisserie-chicken ad, and my hand-rolled probe missed it because the probe
  only read out\regular\ while the engine also reads the ads file. A guard must read what the ENGINE reads.

  CONTRACT (all three must hold, or exit 2):
    1. NO CELL LOST      - every (id,store) priced on the baseline is still priced.
    2. NO PRICE MOVED    - every surviving cell's per_unit is identical (rule edits must not re-price anything;
                           a price change here means a DIFFERENT product won the cell).
    3. NO ROW LOST       - every commodity on the baseline board is still on it.
  Gains are printed, never failed - adding cells is the point.

  Usage:
    verify-no-regression.ps1 -Baseline out\_baseline.json -New out\comparison-2026-07-15.json
  Take the baseline BEFORE the first edit:  Copy-Item out\comparison-<date>.json out\_baseline.json

  -IgnoreIds is for the ONE legitimate case where a price is SUPPOSED to move: the commodities a rule edit
  deliberately targets. Widen chicken-noodle-soup's include and a cheaper real product may win that cell -
  that is the intended outcome, not a regression. Exempting the targets keeps the contract strict where it
  matters (every OTHER commodity, which is where theft shows up) instead of forcing the caller to skip the
  check entirely. Pass ONLY the ids you edited.
#>
param(
  [Parameter(Mandatory = $true)][string]$Baseline,
  [string]$New = "",
  [string[]]$IgnoreIds = @(),
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $New) { $New = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName }

function Cells($p) {
  $j = Read-JsonFile $p
  $h = @{}
  $ids = @{}
  foreach ($r in $j.comparison) {
    $ids[[string]$r.id] = $true
    foreach ($s in $r.stores) { $h[([string]$r.id + '|' + [string]$s.store)] = $s }
  }
  return @{ cells = $h; ids = $ids }
}
$A = Cells $Baseline
$B = Cells $New

$ignore = @{}
foreach ($i in @($IgnoreIds)) { if ($i) { $ignore[[string]$i] = $true } }
function IdOf([string]$k) { return ($k -split '\|')[0] }

$lost = @(); $moved = @(); $gained = @()
foreach ($k in $A.cells.Keys) {
  if ($ignore.ContainsKey((IdOf $k))) { continue }
  if (-not $B.cells.ContainsKey($k)) { $lost += [pscustomobject]@{ k = $k; pu = $A.cells[$k].per_unit; item = $A.cells[$k].item }; continue }
  $p1 = [double]$A.cells[$k].per_unit; $p2 = [double]$B.cells[$k].per_unit
  if ($p1 -gt 0 -and [math]::Abs($p1 - $p2) / $p1 -gt 0.001) {
    $moved += [pscustomobject]@{ k = $k; old = $p1; new = $p2; oldItem = [string]$A.cells[$k].item; newItem = [string]$B.cells[$k].item }
  }
}
foreach ($k in $B.cells.Keys) { if (-not $A.cells.ContainsKey($k)) { $gained += [pscustomobject]@{ k = $k; pu = $B.cells[$k].per_unit; item = $B.cells[$k].item } } }
$rowsLost = @($A.ids.Keys | Where-Object { -not $B.ids.ContainsKey($_) -and -not $ignore.ContainsKey($_) })
if (-not $Quiet -and $ignore.Count) { Write-Output ("  exempt (edited on purpose): " + (($ignore.Keys | Sort-Object) -join ', ')) }

if (-not $Quiet) {
  Write-Output ("verify-no-regression: " + (Split-Path $Baseline -Leaf) + "  ->  " + (Split-Path $New -Leaf))
  Write-Output ("  baseline cells : " + $A.cells.Count)
  Write-Output ("  new cells      : " + $B.cells.Count)
  Write-Output ("  GAINED         : " + $gained.Count)
  foreach ($g in ($gained | Sort-Object k)) { Write-Output ("     + " + $g.k.PadRight(34) + '$' + $g.pu + '  ' + $g.item) }
}
$fail = 0
if ($lost.Count) {
  $fail = 1
  Write-Output ''
  Write-Output ("  CELLS LOST: " + $lost.Count + "  <-- REGRESSION")
  foreach ($l in ($lost | Sort-Object k)) { Write-Output ("     - " + $l.k.PadRight(34) + '$' + $l.pu + '  ' + $l.item) }
}
if ($moved.Count) {
  $fail = 1
  Write-Output ''
  Write-Output ("  PRICES MOVED: " + $moved.Count + "  <-- REGRESSION (a different product won the cell)")
  foreach ($m in ($moved | Sort-Object k)) {
    Write-Output ("     ~ " + $m.k + '   $' + $m.old + ' -> $' + $m.new)
    Write-Output ("         was: " + $m.oldItem)
    Write-Output ("         now: " + $m.newItem)
  }
}
if ($rowsLost.Count) {
  $fail = 1
  Write-Output ''
  Write-Output ("  ROWS LOST: " + $rowsLost.Count + "  <-- REGRESSION: " + (($rowsLost | Select-Object -First 20) -join ', '))
}
if ($fail) { Write-Output ''; Write-Output 'verify-no-regression: FAIL - the change did not only add.'; exit 2 }
Write-Output ("verify-no-regression: OK - nothing lost, nothing re-priced, +" + $gained.Count + " cell(s).")
exit 0
