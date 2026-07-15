<#
  build-nolink-chips.ps1 - assemble the BLR board-match chip lists for the walled stores' no-link chips.
  Joins consistency-report.json (no_link = {id,store}) with the current comparison cell (product name + size),
  emitting per-store [{id, q:'<board product name>', size:'<board size>'}] to out\url-inputs\chips-<slug>.json
  and printing a paste-ready JS array literal (names+sizes only, no URLs). Feed to BLR.run('<store>', CHIPS).
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$slug = @{ "Baker's"='bakers'; 'Aldi'='aldi'; 'Fareway'='fareway' }

$rep = Get-Content (Join-Path $root 'out\consistency-report.json') -Raw | ConvertFrom-Json
$cmpF = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$cmp = Get-Content $cmpF -Raw | ConvertFrom-Json

# (id|store) -> {item,size}
$cell = @{}
foreach ($r in $cmp.comparison) { foreach ($s in $r.stores) { $cell[([string]$r.id + '|' + [string]$s.store)] = $s } }

$outDir = Join-Path $root 'out\url-inputs'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

foreach ($store in $slug.Keys) {
  $chips = New-Object System.Collections.ArrayList
  foreach ($nl in @($rep.no_link)) {
    if ([string]$nl.store -ne $store) { continue }
    $c = $cell[([string]$nl.id + '|' + $store)]
    if (-not $c -or -not ([string]$c.item).Trim()) { continue }
    [void]$chips.Add([ordered]@{ id = [string]$nl.id; q = ([string]$c.item).Trim(); size = ([string]$c.size).Trim() })
  }
  $sl = $slug[$store]
  ($chips | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $outDir ("chips-$sl.json")) -Encoding UTF8
  Write-Output ("$store ($sl): $($chips.Count) chips")
}
