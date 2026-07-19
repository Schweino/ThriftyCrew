$ErrorActionPreference='Stop'
$root='C:\Codex\income\grocery'
$commods = New-Object System.Collections.ArrayList
foreach ($c in (Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json)) { [void]$commods.Add($c) }
$rice = $commods | Where-Object { $_.id -eq 'rice' }
$add = @('\bmirin\b','cooking\s+wine','rice\s+wine','rice\s+vinegar','rice\s+noodle','rice\s+stick','rice\s+cake','rice\s+krispies','rice\s+paper')
$have = @($rice.exclude)
foreach($p in $add){ if($have -notcontains $p){ $have += $p } }
$rice.exclude = $have
($commods | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $root 'commodities.json') -Encoding UTF8
$null = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
Write-Output ('rice excludes now: ' + @($rice.exclude).Count + ' (validated)')
