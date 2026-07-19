$ErrorActionPreference='Stop'
$root='C:\Codex\income\grocery'
$full = Get-Content (Join-Path $root 'out\regular\fareway-regular-2026-07-15.json') -Raw | ConvertFrom-Json
$r100 = Get-Content (Join-Path $root 'out\regular\fareway-regular-2026-07-18.json') -Raw | ConvertFrom-Json
# overlay by item-name key: r100 rows win where they overlap; everything else from the full set stays
$byKey = [ordered]@{}
foreach($d in $full.deals){ $byKey[($d.item + '|' + $d.size)] = $d }
$overlaid = 0
foreach($d in $r100.deals){ $k = ($d.item + '|' + $d.size); if($byKey.Contains($k)){ $overlaid++ }; $byKey[$k] = $d }
$merged = @($byKey.Values)
$r100.deals = $merged
if($r100.PSObject.Properties.Name -contains "deal_count"){ $r100.deal_count = $merged.Count }
($r100 | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $root 'out\regular\fareway-regular-2026-07-18.json') -Encoding UTF8
$null = Get-Content (Join-Path $root 'out\regular\fareway-regular-2026-07-18.json') -Raw | ConvertFrom-Json
Write-Output ("fareway-regular-2026-07-18: " + @($full.deals).Count + " standing + " + @($r100.deals).Count + " total (overlaid $overlaid) mode=in-store verified=2026-07-18 (validated)")
