$ErrorActionPreference='Stop'
$root='C:\Codex\ThriftyCrew\grocery'
$full = Get-Content (Join-Path $root 'out\regular\bakers-regular-2026-07-15.json') -Raw | ConvertFrom-Json
$cap  = Get-Content (Join-Path $root 'out\r100\bakers-r100.json') -Raw | ConvertFrom-Json
$byKey = [ordered]@{}
foreach($d in $full.deals){ $byKey[($d.item + '|' + $d.size)] = $d }
$added=0; $skipped=@()
foreach($c in $cap){
  $name=[string]$c.name; $price=[string]$c.price; $size=[string]$c.size
  # caveat fixes
  if($c.id -eq 'gochujang' -and $size -match 'ct'){ $skipped += ($name + ' (1 ct, no oz basis - Sempio alternate used instead)'); continue }
  if($c.id -eq 'bay-leaves' -and $size -match '(\d+)\s*ct'){ $n=[double]$Matches[1]; $size = ('{0:0.##} oz' -f ($n*0.6/28.3495)) }
  if(($c.id -eq 'tomatillos' -or $c.id -eq 'poblano-peppers') -and $size -match '\$([\d.]+)\s*/\s*lb'){ $price = ('$'+$Matches[1]); $size='lb' }
  $row = [pscustomobject]@{ store="Baker's"; item=$name; ad_price=$price; size=$size; regular=[double]($price -replace '[^0-9.]',''); source_ad="bakersplus.com Pickup Saddlecreek Omaha (r100 capture 2026-07-18)" }
  $byKey[($row.item + '|' + $row.size)] = $row
  $added++
}
# gochujang alternate with a real size
$g = [pscustomobject]@{ store="Baker's"; item='Sempio Gochujang Korean Hot Pepper Paste'; ad_price='$7.49'; size='17.63 oz'; regular=7.49; source_ad="bakersplus.com Pickup Saddlecreek Omaha (r100 capture 2026-07-18)" }
$byKey[($g.item + '|' + $g.size)] = $g; $added++
$full.deals = @($byKey.Values)
if($full.PSObject.Properties.Name -contains 'deal_count'){ $full.deal_count = @($full.deals).Count }
($full | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $root 'out\regular\bakers-regular-2026-07-18.json') -Encoding UTF8
$check = Get-Content (Join-Path $root 'out\regular\bakers-regular-2026-07-18.json') -Raw | ConvertFrom-Json
Write-Output ("bakers-regular-2026-07-18: " + @($check.deals).Count + " rows (+$added) (validated)")
if($skipped){ Write-Output ("skipped: " + ($skipped -join '; ')) }
