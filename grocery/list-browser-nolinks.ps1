$r = Get-Content "$PSScriptRoot\out\consistency-report.json" -Raw | ConvertFrom-Json
$cmp = Get-Content (Get-ChildItem "$PSScriptRoot\out\comparison-*.json" | Sort-Object Name -Descending | Select-Object -First 1).FullName -Raw | ConvertFrom-Json
$bd = @{}
foreach ($it in $cmp.comparison) {
  foreach ($s in $it.stores) {
    $bd[($it.id + '|' + $s.store)] = [pscustomobject]@{ item=[string]$s.item; size=[string]$s.size; unit=[string]$it.unit }
  }
}
foreach ($store in @("Baker's", 'Walmart', 'Aldi', "Sam's Club", 'Fareway')) {
  $chips = @($r.no_link | Where-Object { [string]$_.store -eq $store })
  Write-Output ("### $store  ($($chips.Count))")
  foreach ($c in $chips) {
    $b = $bd[([string]$c.id + '|' + $store)]
    $item = if ($b) { $b.item } else { '?' }
    $size = if ($b) { $b.size } else { '?' }
    Write-Output ('   {0,-22} board=<{1}>  size={2}' -f [string]$c.id, $item, $size)
  }
}
