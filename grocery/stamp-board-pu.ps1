<#
  stamp-board-pu.ps1 - Part of the product-URL automation.
  Writes a 'board_pu' field onto every stored link in product-urls.json = the board (weekly ad / recipe)
  per-unit price for that item x store AT THE TIME OF STAMPING. resolve-worklist.ps1 then flags a link
  'stale' only when the CURRENT board per-unit has moved away from this snapshot (i.e. a new ad changed the
  item), NOT merely because the verified shelf price differs from the ad price. Run this right after a
  successful merge so freshly resolved links are marked current. Idempotent.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$outDir = Join-Path $root 'out'

$cmpFile = (Get-ChildItem (Join-Path $outDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$cmp = (Read-JsonFile $cmpFile).comparison
$ri = @()
$riFile = Join-Path $outDir 'recipe-board.json'
if (Test-Path $riFile) { $ri = (Read-JsonFile $riFile).comparison }

# TWO separate snapshots: the weekly board and the recipe board can carry DIFFERENT figures for the same
# id+store (butter: staple $/lb vs recipe $/oz; peanut-butter: staple ad-sale vs recipe everyday floor).
# A single scalar snapshot made every dual-board id false-stale forever (butter flagged stale(1500%) at all
# 6 stores). board_pu = weekly comparison; recipe_pu = recipe board. resolve-worklist compares each chip
# occurrence against ITS OWN board's snapshot.
$board = @{}   # weekly: id -> store -> per_unit
foreach ($it in $cmp) {
  $id = [string]$it.id
  if (-not $board.ContainsKey($id)) { $board[$id] = @{} }
  foreach ($s in $it.stores) { $board[$id][[string]$s.store] = [double]$s.per_unit }
}
$rboard = @{}  # recipe: id -> store -> per_unit
foreach ($it in $ri) {
  $id = [string]$it.id
  if (-not $rboard.ContainsKey($id)) { $rboard[$id] = @{} }
  foreach ($s in $it.stores) { $rboard[$id][[string]$s.store] = [double]$s.per_unit }
}

# Chips still on the worklist (stale/mismatch not yet re-resolved) must NOT be re-stamped: setting
# board_pu=current would erase their 'stale' signal so they'd never re-flag. Only stamp resolved/current
# links. (Run this AFTER a fresh resolve-worklist so the flag set reflects the post-merge state.)
$flagged = @{}
$wlFile = Join-Path $outDir 'url-worklist.json'
if (Test-Path $wlFile) { try { $wl = Read-JsonFile $wlFile; foreach ($stN in $wl.stores.PSObject.Properties.Name) { foreach ($c in @($wl.stores.$stN)) { $flagged[([string]$c.id + '|' + $stN)] = $true } } } catch {} }

$pf = Join-Path $root 'product-urls.json'
$pd = Read-JsonFile $pf
$stamped = 0; $skipped = 0
foreach ($p in $pd.items.PSObject.Properties) {
  $id = [string]$p.Name
  foreach ($sp in $p.Value.PSObject.Properties) {
    if ($sp.Name -eq 'commodity') { continue }
    $store = [string]$sp.Name
    if ($flagged.ContainsKey($id + '|' + $store)) { $skipped++; continue }
    $did = $false
    if ($board.ContainsKey($id) -and $board[$id].ContainsKey($store)) {
      $bpu = $board[$id][$store]
      if ($sp.Value.PSObject.Properties.Name -contains 'board_pu') { $sp.Value.board_pu = $bpu }
      else { $sp.Value | Add-Member -NotePropertyName board_pu -NotePropertyValue $bpu -Force }
      $did = $true
    }
    if ($rboard.ContainsKey($id) -and $rboard[$id].ContainsKey($store)) {
      $rpu = $rboard[$id][$store]
      if ($sp.Value.PSObject.Properties.Name -contains 'recipe_pu') { $sp.Value.recipe_pu = $rpu }
      else { $sp.Value | Add-Member -NotePropertyName recipe_pu -NotePropertyValue $rpu -Force }
      $did = $true
    }
    if ($did) { $stamped++ }
  }
}
$pd | ConvertTo-Json -Depth 6 | Set-Content $pf -Encoding UTF8
Write-Output ("stamped board_pu on " + $stamped + " links (skipped " + $skipped + " still-flagged/unresolved)")
