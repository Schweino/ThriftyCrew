$root = 'C:\Codex\income\grocery'
$pu = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items
$cmp = Get-Content (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Desc | Select-Object -First 1).FullName -Raw | ConvertFrom-Json
$targets = @(
  @('coffee','Family Fare'), @('spinach','Aldi'), @('strawberries','Hy-Vee'),
  @('sweet-corn',"Baker's"), @('yeast','Hy-Vee'), @('yeast','Fareway')
)
foreach ($t in $targets) {
  $id = $t[0]; $store = $t[1]
  $row = $cmp.comparison | Where-Object { $_.id -eq $id }
  $cell = $row.stores | Where-Object { $_.store -eq $store }
  $e = $pu.$id.$store
  Write-Output (($id + ' / ' + $store).ToUpper() + '   (unit=' + $row.unit + ')')
  Write-Output ('   ENGINE cell : ' + $cell.item + '   per=' + $cell.per_unit + '  size=[' + $cell.size + ']  ad=' + $cell.ad)
  Write-Output ('   LINK        : ' + $e.name + '   price=' + $e.price + '  size=[' + $e.size + ']')
  Write-Output ''
}
