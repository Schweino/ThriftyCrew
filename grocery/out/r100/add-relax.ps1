$ErrorActionPreference='Stop'
$root='C:\Codex\income\grocery'
$commods = New-Object System.Collections.ArrayList
foreach ($c in (Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json)) { [void]$commods.Add($c) }
$MIX = '\bmix\b(?!\s*(?:&|and)\s*match)'
$relaxMap = @{
  'fish-sauce'          = @('\bsauce\b')
  'oyster-sauce'        = @('\bsauce\b')
  'hoisin-sauce'        = @('\bsauce\b')
  'gochujang'           = @('\bsauce\b')
  'mirin'               = @('\bwine\b')
  'chipotle-adobo'      = @('\bsauce\b','\bcanned\b')
  'corn-muffin-mix'     = @('muffin', $MIX, '\bbake\b','\bbaked\b')
  'japanese-curry-roux' = @('\bsauce\b', $MIX)
  'ranch-seasoning-mix' = @($MIX, '\bdip\b')
  'taco-seasoning'      = @($MIX)
  'cheese-tortellini'   = @('\bfrozen\b')
  'red-curry-paste'     = @('\bsauce\b')
  'harissa-paste'       = @('\bsauce\b')
  'chili-crisp'         = @('\bsauce\b')
}
foreach ($kv in $relaxMap.GetEnumerator()) {
  $e = $commods | Where-Object { $_.id -eq $kv.Key }
  if (-not $e) { Write-Output ("MISSING commodity: " + $kv.Key); continue }
  $e | Add-Member -NotePropertyName relax_global -NotePropertyValue @($kv.Value) -Force
}
# gochujang: remove my own sauce exclude (the carried product IS 'Gochujang Sauce')
$g = $commods | Where-Object { $_.id -eq 'gochujang' }
$g.exclude = @(@($g.exclude) | Where-Object { $_ -ne '\bsauce\b' })
($commods | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $root 'commodities.json') -Encoding UTF8
$null = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
Write-Output ('relax_global added to ' + $relaxMap.Count + ' commodities (validated)')
