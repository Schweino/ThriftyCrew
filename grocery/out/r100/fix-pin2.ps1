$ErrorActionPreference='Stop'
$root='C:\Codex\ThriftyCrew\grocery'
$f = Join-Path $root 'board-price-overrides.json'
$doc = Get-Content $f -Raw | ConvertFrom-Json
# shape-agnostic: find the array property holding {id,store,...} pins
$arrProp = $null
foreach($p in $doc.PSObject.Properties){ if($p.Value -is [array] -and @($p.Value).Count -gt 0 -and $p.Value[0].PSObject.Properties.Name -contains 'id'){ $arrProp = $p.Name; break } }
if(-not $arrProp){ throw ('no pin array found; props: ' + (($doc.PSObject.Properties.Name) -join ',')) }
$before = @($doc.$arrProp).Count
$doc.$arrProp = @($doc.$arrProp | Where-Object { -not ($_.id -eq 'dried-thyme' -and $_.store -eq 'Family Fare') })
($doc | ConvertTo-Json -Depth 6) | Set-Content $f -Encoding UTF8
$null = Get-Content $f -Raw | ConvertFrom-Json
Write-Output ("pins($arrProp): $before -> " + @($doc.$arrProp).Count)
