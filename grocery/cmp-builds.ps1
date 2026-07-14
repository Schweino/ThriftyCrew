$o = Get-Content 'C:\Codex\income\grocery\board-price-overrides.json' -Raw | ConvertFrom-Json
Write-Output ('override cells now: ' + @($o.cells).Count)
foreach ($c in $o.cells) { if ($c.id -match 'gelatin|yeast') { Write-Output ('  PIN BACK: ' + $c.id + ' / ' + $c.store + ' = ' + $c.per_unit) } }
Write-Output ''
Write-Output 'What product-urls.json still has linked for these cells:'
$pu = (Get-Content 'C:\Codex\income\grocery\product-urls.json' -Raw | ConvertFrom-Json).items
foreach ($id in @('gelatin','yeast')) {
  $e = $pu.$id
  if (-not $e) { Write-Output ("  " + $id + ": no entry"); continue }
  foreach ($store in @('Walmart','Hy-Vee','Fareway')) {
    $s = $e.$store
    if ($s) { Write-Output ("  {0,-8} {1,-9} price={2} size={3}  name={4}" -f $id, $store, $s.price, $s.size, $s.name) }
  }
}
