$b = Get-Content 'C:\Codex\income\grocery\out\everyday-mismatches.json' -Raw | ConvertFrom-Json
$same = @($b | Where-Object { $_.boardItem -eq $_.linkItem })
$drift = @($b | Where-Object { $_.boardItem -ne $_.linkItem })
Write-Output ("SAME PRODUCT, DIFFERENT PRICE  (a real number is wrong): " + $same.Count)
foreach ($x in $same) {
  Write-Output ("  {0,-22} {1,-12} board={2,-9} link={3,-9} x{4}  `${5} [{6}]  {7}" -f $x.id, $x.store, $x.board, $x.link, $x.ratio, $x.price, $x.size, $x.linkItem)
}
Write-Output ''
Write-Output ("LINK POINTS AT A DIFFERENT PRODUCT (stale link, board may be right): " + $drift.Count)
foreach ($x in $drift) {
  Write-Output ("  {0,-22} {1,-12} x{2}" -f $x.id, $x.store, $x.ratio)
  Write-Output ("       board: " + $x.boardItem)
  Write-Output ("       link : " + $x.linkItem)
}
