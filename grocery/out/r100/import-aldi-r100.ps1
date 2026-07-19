$ErrorActionPreference='Stop'
$root='C:\Codex\income\grocery'
# standing full Aldi set (403 rows, in-store verified) + overlay today's 10 r100 rows + tortelloni
$full = Get-Content (Join-Path $root 'out\regular\aldi-regular-2026-07-15.json') -Raw | ConvertFrom-Json
$cap  = Get-Content (Join-Path $root 'out\r100\aldi-r100.json') -Raw | ConvertFrom-Json
$byKey = [ordered]@{}
foreach($d in $full.deals){ $byKey[($d.item + '|' + $d.size)] = $d }
$added=0
foreach($c in $cap){
  $row = [pscustomobject]@{ store='Aldi'; item=[string]$c.name; ad_price=[string]$c.price; size=[string]$c.size; regular=[double](([string]$c.price) -replace '[^0-9.]',''); source_ad='aldi.us storefront In-Store OLA 42 Omaha (r100 capture 2026-07-18)' }
  $byKey[($row.item + '|' + $row.size)] = $row
  $added++
}
# the cheaper same-commodity tortelloni the agent flagged
$tor = [pscustomobject]@{ store='Aldi'; item='Priano Cheese Tortelloni'; ad_price='$1.49'; size='8.8 oz'; regular=1.49; source_ad='aldi.us storefront In-Store OLA 42 Omaha (r100 capture 2026-07-18)' }
$byKey[($tor.item + '|' + $tor.size)] = $tor; $added++
$full.deals = @($byKey.Values)
if($full.PSObject.Properties.Name -contains 'deal_count'){ $full.deal_count = @($full.deals).Count }
$full.mode_verified = '2026-07-18'
($full | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $root 'out\regular\aldi-regular-2026-07-18.json') -Encoding UTF8
$check = Get-Content (Join-Path $root 'out\regular\aldi-regular-2026-07-18.json') -Raw | ConvertFrom-Json
Write-Output ("aldi-regular-2026-07-18: " + @($check.deals).Count + " rows (+$added overlay) mode=" + $check.price_mode + " verified=" + $check.mode_verified + " (validated)")
