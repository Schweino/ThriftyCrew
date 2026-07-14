. "$PSScriptRoot\pu-lib.ps1"
$pd = (Get-Content "$PSScriptRoot\product-urls.json" -Raw | ConvertFrom-Json).items

# sample a few "# oz" cells that came back unparseable - is the PRICE missing?
foreach ($pair in @(@('chili-powder','Walmart'),@('garlic-powder','Aldi'),@('onion-powder','Walmart'),@('italian-seasoning',"Sam's Club"))) {
  $e = $pd.($pair[0]).($pair[1])
  if ($e) { Write-Output ('{0} [{1}]  price=<{2}>  size=<{3}>  hasUrl={4}' -f $pair[0].PadRight(18), $pair[1], ([string]$e.price), ([string]$e.size), ([bool]$e.url)) }
  else    { Write-Output ('{0} [{1}]  (no entry)' -f $pair[0].PadRight(18), $pair[1]) }
}
Write-Output ''

$cmp = Get-Content (Get-ChildItem "$PSScriptRoot\out\comparison-*.json" | Sort-Object Name -Descending | Select-Object -First 1).FullName -Raw | ConvertFrom-Json
$all = @($cmp.comparison)
if (Test-Path "$PSScriptRoot\out\recipe-board.json") { $all += @((Get-Content "$PSScriptRoot\out\recipe-board.json" -Raw | ConvertFrom-Json).comparison) }

$noPrice=0; $emptySize=0; $multipack=0; $unitMismatch=0; $other=0
foreach ($it in $all) {
  $id = [string]$it.id; $unit = [string]$it.unit
  foreach ($s in $it.stores) {
    if ([double]$s.per_unit -le 0) { continue }
    if (([string]$s.type) -ne 'everyday') { continue }
    $e = $pd.$id.($([string]$s.store))
    if (-not ($e -and $e.url)) { continue }
    $sp = 0.0; [void][double]::TryParse((([string]$e.price) -replace '[^0-9.]',''), [ref]$sp)
    if ($null -ne (Get-LinkPerUnit -size ([string]$e.size) -unit $unit -price $sp -name ([string]$e.name))) { continue }
    $sz = ([string]$e.size).Trim()
    if     ($sp -le 0)                       { $noPrice++ }
    elseif ($sz -eq '')                      { $emptySize++ }
    elseif ($sz -match '\bpk\b|\bpack\b')    { $multipack++ }
    elseif ($sz -match '\bea\b|each|loaf' -or ($unit -in @('each','lb') -and $sz -match 'oz')) { $unitMismatch++ }
    else                                     { $other++ }
  }
}
Write-Output ("unparseable breakdown:  missing-price=$noPrice  empty-size=$emptySize  multipack=$multipack  unit-mismatch=$unitMismatch  other=$other")
