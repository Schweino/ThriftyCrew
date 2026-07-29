<#
  build-pull-order.ps1 - emit this store's search terms in SHOPPER-VALUE order, so a bot wall truncates the
  long tail instead of the staples.

  *** WHY THIS EXISTS ***
  Walmart and Sam's are pulled through the browser and both hit a hard human-verification wall partway
  through the run. On 2026-07-29 Walmart died after 55 of 526 terms and Sam's after 205. Because the term
  list is in commodity-search.json order - which is roughly the order commodities were ADDED, not the order
  they matter - the wall landed wherever it landed, and the 55 terms we got were not the 55 that matter.
  The capture built 64 priced rows against 1351 in the previous file, so it had to be quarantined whole and
  the store went stale.

  A wall is not preventable. Losing the staples to it is. Pull the terms that actually reach the board first
  and the same wall costs the long tail instead: aji amarillo paste and pomegranate molasses go stale rather
  than milk, eggs and chicken breast.

  *** THE RANKING - and why HISTORY DEPTH is the signal ***
  "Contested by N stores" does not discriminate: the board is dense, so ~360 of 526 terms are carried by 5+
  stores and a tier built on that is no better than alphabetical. What DOES separate them is how long a
  commodity has been tracked. price-history.json banks a row per run, so depth encodes the order commodities
  entered the project - and the deepest 29 are exactly the founding staple basket Brad curated:

      milk, eggs, bread, butter, bacon, chicken breast, chicken thighs, 80/20 ground beef, ground turkey,
      pork chops, coffee, peanut butter, yogurt, cottage cheese, cream cheese, sour cream, shredded cheese,
      orange juice, bananas, apples, grapes, peaches, strawberries, blueberries, avocados, watermelon,
      sweet corn, russet potatoes, onions

  Everything after that arrived in later expansion batches, in descending depth. So the sort is:
      1. history depth  (founding staples first, then each expansion wave in the order it was added)
      2. how contested the commodity is
      3. whether THIS store already publishes a cell (refresh what we publish before chasing new coverage)

  The output still names the SAFE STOP - the term count covering every cell this store publishes today -
  but the point of the ordering is that stopping ANYWHERE now costs the tail rather than the basket.

  The output names the SAFE STOP: the term count that covers every cell this store currently publishes.
  Stopping there is a complete pull of everything the store contributes today.

  Usage: .\build-pull-order.ps1 -Store Walmart
         .\build-pull-order.ps1 -All
#>
param(
  [string]$Store = "",
  [switch]$All,
  [string]$OutDir = ""
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\income\grocery' }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

$searchDoc = Get-Content (Join-Path $root 'commodity-search.json') -Raw | ConvertFrom-Json
$terms = @{}
foreach ($p in $searchDoc.terms.PSObject.Properties) { $terms[$p.Name] = [string]$p.Value }

$cmpFile = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1
if (-not $cmpFile) { throw 'build-pull-order: no comparison-*.json - run compare-deals first' }
$cmp = Get-Content $cmpFile.FullName -Raw | ConvertFrom-Json

$storesSeen = @{}
$onBoard = @{}
foreach ($r in @($cmp.comparison)) {
  $onBoard[$r.id] = @($r.stores).Count
  foreach ($s in @($r.stores)) { $storesSeen[("$($r.id)|$($s.store)")] = 1 }
}

# how long each commodity has been tracked = the order it entered the project = how staple it is
$depth = @{}
$hPath = Join-Path $root 'price-history.json'
if (Test-Path $hPath) {
  $hist = Get-Content $hPath -Raw | ConvertFrom-Json
  foreach ($c in @($hist.commodities)) { $depth[[string]$c.id] = @($c.history).Count }
}

$targets = if ($All) { @('Walmart', "Sam's Club", 'Aldi', "Baker's", 'Hy-Vee', 'Fareway', 'Family Fare') } elseif ($Store) { @($Store) } else { throw 'build-pull-order: pass -Store <name> or -All' }

foreach ($st in $targets) {
  $rows = New-Object System.Collections.ArrayList
  foreach ($id in $terms.Keys) {
    $contest = if ($onBoard.ContainsKey($id)) { [int]$onBoard[$id] } else { 0 }
    $has = $storesSeen.ContainsKey("$id|$st")
    $d = if ($depth.ContainsKey($id)) { [int]$depth[$id] } else { 0 }
    $tier = if ($has -and $contest -ge 5) { 1 } elseif ($has) { 2 } elseif ($contest -gt 0) { 3 } else { 4 }
    [void]$rows.Add([pscustomobject]@{ tier = $tier; contest = $contest; depth = $d; has = [int]$has; id = $id; term = $terms[$id] })
  }
  $ordered = @($rows.ToArray() | Sort-Object @{e='depth';Descending=$true}, @{e='contest';Descending=$true}, @{e='has';Descending=$true}, @{e='id'})

  $slug = ($st.ToLower() -replace "[^a-z0-9]", '')
  $file = Join-Path $OutDir ("pull-order-$slug.txt")
  $lines = New-Object System.Collections.ArrayList
  foreach ($r in $ordered) { [void]$lines.Add(("{0}`t{1}" -f $r.id, $r.term)) }
  Set-Content -Path $file -Value $lines.ToArray() -Encoding UTF8

  $t1 = @($ordered | Where-Object { $_.tier -eq 1 }).Count
  $t2 = @($ordered | Where-Object { $_.tier -eq 2 }).Count
  $t3 = @($ordered | Where-Object { $_.tier -eq 3 }).Count
  $t4 = @($ordered | Where-Object { $_.tier -eq 4 }).Count
  Write-Output ("{0,-12} terms={1,4}   T1 core={2,4}  T2 held={3,4}  T3 gain={4,4}  T5 tail={5,4}   SAFE STOP after {6} terms (covers every cell this store publishes today)  -> {7}" -f $st, $ordered.Count, $t1, $t2, $t3, $t4, ($t1 + $t2), (Split-Path $file -Leaf))
}
