$ErrorActionPreference='Stop'
$root = 'C:\Codex\income\grocery'
# commodities: drop diced-green-chiles
$commods = New-Object System.Collections.ArrayList
foreach ($c in (Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json)) {
  if ($c.id -ne 'diced-green-chiles') { [void]$commods.Add($c) }
}
($commods | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $root 'commodities.json') -Encoding UTF8
# categories: remove from its category list
$catDoc = Get-Content (Join-Path $root 'categories.json') -Raw | ConvertFrom-Json
foreach ($cat in $catDoc.categories) { $cat.commodities = @(@($cat.commodities) | Where-Object { $_ -ne 'diced-green-chiles' }) }
($catDoc | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $root 'categories.json') -Encoding UTF8
# search terms: drop
$searchDoc = Get-Content (Join-Path $root 'commodity-search.json') -Raw | ConvertFrom-Json
$searchDoc.terms.PSObject.Properties.Remove('diced-green-chiles') | Out-Null
($searchDoc | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $root 'commodity-search.json') -Encoding UTF8
# validate round-trips
$null = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
$null = Get-Content (Join-Path $root 'categories.json') -Raw | ConvertFrom-Json
$null = Get-Content (Join-Path $root 'commodity-search.json') -Raw | ConvertFrom-Json
Write-Output 'diced-green-chiles deregistered from all three files (validated)'
