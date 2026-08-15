$ErrorActionPreference='Stop'
$root='C:\Codex\ThriftyCrew\grocery'
$f = Join-Path $root 'out\regular\walmart-regular-2026-07-18.json'
$doc = Get-Content $f -Raw | ConvertFrom-Json
$deals = New-Object System.Collections.ArrayList
foreach($d in $doc.deals){ [void]$deals.Add($d) }
$before = $deals.Count
# rows had no Walmart unit-price field; size comes straight from the product NAME (importer convention)
[void]$deals.Add([pscustomobject]@{ store='Walmart'; item='Morton & Bassett Berbere Seasoning, 1.3 oz - Spice Blend'; ad_price='$6.49'; size='1.3 oz'; regular=6.49; source_ad='walmart.com search (r100 capture, size from product name)' })
[void]$deals.Add([pscustomobject]@{ store='Walmart'; item='NY SPICE SHOP Ethiopian Berbere Spice Seasoning - 1 Pound'; ad_price='$17.67'; size='16 oz'; regular=17.67; source_ad='walmart.com search (r100 capture, size from product name)' })
$doc.deals = $deals.ToArray()
($doc | ConvertTo-Json -Depth 6) | Set-Content $f -Encoding UTF8
$null = Get-Content $f -Raw | ConvertFrom-Json
Write-Output ("walmart-regular: $before -> $($doc.deals.Count) rows (berbere added, validated)")
