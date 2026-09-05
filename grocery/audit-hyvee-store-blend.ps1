<#
  audit-hyvee-store-blend.ps1 - is the Hy-Vee everyday file a BLEND of two stores?

  WHY THIS EXISTS (2026-08-21). Brad ruled that the board should speak for Omaha #02 instead of Omaha
  #01. The code switched in one commit. The DATA cannot: capture policy refreshes 7 Hy-Vee products a
  day against 1554 rows, so the file becomes a mixture the moment the next rotation lands and stays one
  for up to a full 90-day quarter.

  A BLEND IS INVISIBLE TO EVERY OTHER GUARD, WHICH IS THE WHOLE POINT OF THIS FILE. Each row is real,
  each price reproduces against the store that supplied it, the arithmetic checks out, the links resolve.
  Nothing in the estate compares a row's STORE against the store the board claims - so a board that is
  40% Omaha #01 and 60% Omaha #02 reads exactly like a clean one.

  AND THE TWO STORES GENUINELY DISAGREE. Measured the same day on real rows:
      sale rows      22 on sale at #01, only 6 at #02; 13 of 22 priced differently, #01 cheaper in all 13
      everyday rows  13 of 37 sampled priced differently, in BOTH directions
                     (asparagus 4.99 -> 5.99, Lysol 7.69 -> 6.99)
  So roughly a third of everyday rows and most sale rows are wrong for the store the board now claims.
  This is not a rounding concern.

  Advisory by design, and deliberately so: the blend is a KNOWN, ACCEPTED state during a migration
  Brad chose. What must never happen is for it to become an unknown one. This reports the mixture and
  its size every run, so "how far through the switch are we" is a number somebody can read rather than
  a thing nobody is tracking.

  Usage: audit-hyvee-store-blend.ps1 [-OutDir <dir>] [-Quiet]
  Exit 0 always (advisory). Exit 3 = BLIND (no file to read).
#>
param([string]$OutDir = '', [switch]$Quiet)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
. (Join-Path (Split-Path $root -Parent) 'lib\guard-contract.ps1')
. (Join-Path $root 'hyvee-store-lib.ps1')

$f = Get-ChildItem (Join-Path $OutDir 'regular\hyvee-regular-*.json') -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if (-not $f) {
  Write-Output 'hyvee-store-blend: no Hy-Vee everyday file found'
  Write-GuardComplete -Name 'hyvee-store-blend' -Summary 'BLIND: no file'
  exit 3
}
$doc = Read-JsonFile $f.FullName
$rows = @($doc.deals)
$want = Get-HyVeeStore -Root $root
$wantId = [int]$want.store_id

# A row states its store in source_ad, written by the puller from the identity it actually queried.
# Reading the row's OWN claim rather than inferring from the file date is what makes this honest: a
# file named today can hold rows captured across 31 different days, and it does.
$byStore = @{}
foreach ($r in $rows) {
  $m = [regex]::Match([string]$r.source_ad, 'storeId\s+(\d+)')
  $k = if ($m.Success) { $m.Groups[1].Value } else { 'unstated' }
  if (-not $byStore.ContainsKey($k)) { $byStore[$k] = 0 }
  $byStore[$k]++
}
$onTarget = if ($byStore.ContainsKey([string]$wantId)) { [int]$byStore[[string]$wantId] } else { 0 }
$offTarget = 0
foreach ($k in $byStore.Keys) { if ($k -ne [string]$wantId -and $k -ne 'unstated') { $offTarget += [int]$byStore[$k] } }
$unstated = if ($byStore.ContainsKey('unstated')) { [int]$byStore['unstated'] } else { 0 }
$total = $rows.Count
$pct = if ($total) { [math]::Round(100.0 * $onTarget / $total, 1) } else { 0 }

$doc2 = [ordered]@{
  updated = (Get-Date).ToString('s')
  file = $f.Name
  board_speaks_for = ("{0} (storeId {1})" -f $want.label, $wantId)
  rows = $total
  on_target = $onTarget
  off_target = $offTarget
  unstated = $unstated
  migrated_pct = $pct
  by_store_id = ($byStore.Keys | Sort-Object | ForEach-Object { "$_=$($byStore[$_])" }) -join ' '
  note = 'A row states its own store in source_ad. off_target rows were captured at a store the board no longer speaks for and are NOT wrong in themselves - they are simply another store''s prices. Measured 2026-08-21: the two Omaha stores disagree on ~35% of everyday rows and most sale rows, so off_target is a direct count of how many cells are likely wrong for the claimed store. unstated rows predate source_ad carrying an id and cannot be attributed either way.'
}
$out = Join-Path $OutDir 'hyvee-store-blend.json'
[IO.File]::WriteAllText($out, ($doc2 | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))

if (-not $Quiet) {
  Write-Output ("hyvee-store-blend  -  board speaks for {0} (storeId {1})" -f $want.label, $wantId)
  Write-Output ("  {0} row(s): {1} on target, {2} from a RETIRED store, {3} unstated  ->  {4}% migrated" -f $total, $onTarget, $offTarget, $unstated, $pct)
  Write-Output ("  by storeId: " + $doc2.by_store_id)
  if ($offTarget -gt 0) {
    Write-Output ("  NOTE: {0} row(s) still carry another store's prices. The two Omaha stores disagree on roughly a third" -f $offTarget)
    Write-Output  '        of everyday rows and most sale rows, so this is a live count of cells likely wrong for the claimed store.'
  }
  Write-Output ("  -> " + $out)
}
Write-GuardComplete -Name 'hyvee-store-blend' -Summary "rows=$total on=$onTarget off=$offTarget pct=$pct"
exit 0
