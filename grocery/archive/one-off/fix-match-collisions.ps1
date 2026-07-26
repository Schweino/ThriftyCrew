<#
  fix-match-collisions.ps1 - close the order-dependent matches found by audit-match-contested.ps1.

  Each of these rows was being claimed by the WRONG commodity and only lost the board cell because
  it happened not to be the cheapest per-unit. That is luck, not correctness - a price change would
  have handed the cell to a box of crackers.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$c = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
Copy-Item (Join-Path $root 'commodities.json') (Join-Path $root 'out\commodities.backup-precollisionfix.json') -Force

function Add-Exclude($id, $patterns) {
  $m = $c | Where-Object { $_.id -eq $id }
  if (-not $m) { Write-Output "  ?? no commodity $id"; return }
  $ex = New-Object System.Collections.ArrayList
  foreach ($e in $m.exclude) { [void]$ex.Add([string]$e) }
  foreach ($p in $patterns) { if (-not $ex.Contains($p)) { [void]$ex.Add($p) } }
  $m.exclude = $ex.ToArray()
  Write-Output ("  {0,-18} +{1}" -f $id, ($patterns -join ' '))
}
function Set-Include($id, $patterns) {
  $m = $c | Where-Object { $_.id -eq $id }
  $m.include = $patterns
  Write-Output ("  {0,-18} include REWRITTEN" -f $id)
}

# 1. BUG I INTRODUCED TODAY: no word boundary, so "disinfect-ANT SPRAY" matched "ant spray".
#    Same family as the bare-'air'-matches-'hair' lesson.
Set-Include 'insect-spray' @('\b(?:ant|roach|insect|bug|spider)s?\b[\s&]+(?:killer|spray)','\braid\b','hot\s+shot','home\s+insect')

# 2. "k[\s-]?cups?" matched the "k Cups" inside "Pac-K CUPS" -> a fruit cup 4-pack was matching coffee pods.
Set-Include 'coffee-pods' @('\bk[\s-]?cups?\b','coffee\s+pods?','single\s+serve\s+coffee','\bcoffee\s+cups\b')

# 3. "apple\s+juice" matched the "apple juice" inside "PINE-APPLE JUICE".
Add-Exclude 'apple-juice' @('pineapple')

# 4. Triscuit "Avocado, Cilantro & Lime" crackers and "Vigo Lime Rice" were both matching LIMES.
Add-Exclude 'limes' @('\bcrackers?\b','\brice\b','\bchips?\b','\btortilla\b','\bseasoning\b','\bsalsa\b','\bcandy\b')

# 5. "Bomb Pop Pops, Strawberry, Watermelon & Grape, Nerds Candy" was matching GRAPES.
Add-Exclude 'grapes' @('\bpops?\b','popsicle','\bcandy\b','\bnerds\b','freeze\s*pop','ice\s*pop')

# 6. "Our Family Tomatoes ... Green Bell Pepper, Diced, Petite" (a can of diced tomatoes)
#    was matching BELL-PEPPERS.
Add-Exclude 'bell-peppers' @('\btomato(?:es)?\b','\bdiced\b')

# 7. "Fresh & Finest 8 Ct Egg Hamburger Buns" was matching EGGS.
Add-Exclude 'eggs' @('\bbuns?\b','\bbagels?\b','\bbread\b','\brolls?\b','\bloaf\b')

# 8. "Kale Lettuce Bunch" was taking Baker's LETTUCE cell. Kale is its own commodity.
Add-Exclude 'lettuce' @('\bkale\b')

($c | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $root 'commodities.json') -Encoding UTF8
Write-Output ''
Write-Output 'commodities.json updated (backup: out\commodities.backup-precollisionfix.json)'
