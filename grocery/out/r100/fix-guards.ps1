$ErrorActionPreference='Stop'
$root='C:\Codex\income\grocery'

# 1) fence BUTTER against butter-FLAVORED products (my biscuit capture hijacked its Walmart cell)
$commods = New-Object System.Collections.ArrayList
foreach ($c in (Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json)) { [void]$commods.Add($c) }
$butter = $commods | Where-Object { $_.id -eq 'butter' }
$add = @('\bbiscuits?\b','butter\s+flav','flavou?red','\bcroissants?\b','\brolls?\b','\bcookie','\bpopcorn\b','\bspray\b')
$have = @($butter.exclude)
foreach($p in $add){ if($have -notcontains $p){ $have += $p } }
$butter.exclude = $have
($commods | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $root 'commodities.json') -Encoding UTF8
$null = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
Write-Output ('butter excludes: ' + @($butter.exclude).Count + ' (validated)')

# 2) prune the 4 truncated-name multipack rows from walmart-regular
$wf = Join-Path $root 'out\regular\walmart-regular-2026-07-18.json'
$doc = Get-Content $wf -Raw | ConvertFrom-Json
$before = @($doc.deals).Count
$doc.deals = @($doc.deals | Where-Object { $_.item -notmatch '^\(\d+\s*[Pp]ack\)' })
($doc | ConvertTo-Json -Depth 6) | Set-Content $wf -Encoding UTF8
$null = Get-Content $wf -Raw | ConvertFrom-Json
Write-Output ("walmart-regular multipack prune: $before -> " + @($doc.deals).Count)

# 3) remove auto-derived product-urls entries for r100 ids (links re-derive AFTER cells settle)
$pu = Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json
$r100 = Get-Content (Join-Path $root 'out\r100\r100-ids.txt')
$removed=0
foreach($id in $r100){ if($pu.items.PSObject.Properties.Name -contains $id){ $pu.items.PSObject.Properties.Remove($id); $removed++ } }
($pu | ConvertTo-Json -Depth 8) | Set-Content (Join-Path $root 'product-urls.json') -Encoding UTF8
$null = Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json
Write-Output ("product-urls: removed $removed r100 auto-derived entries (validated)")
