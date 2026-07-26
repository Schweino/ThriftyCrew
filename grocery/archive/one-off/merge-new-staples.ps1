<#
  merge-new-staples.ps1 - one-shot merge of new-staples-2026-07-12.json (the top-100 expansion) into
  commodities.json + categories.json + commodity-search.json. Idempotent: skips ids/keys that already exist.
#>
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$src = Get-Content (Join-Path $root 'new-staples-2026-07-12.json') -Raw | ConvertFrom-Json

# ---- commodities.json (array) ----
$cf = Join-Path $root 'commodities.json'
$commods = [System.Collections.ArrayList]@((Get-Content $cf -Raw | ConvertFrom-Json))
$have = @{}; foreach ($c in $commods) { $have[[string]$c.id] = $true }
$added = 0
foreach ($n in $src.commodities) {
  if ($have.ContainsKey([string]$n.id)) { continue }
  [void]$commods.Add($n); $added++
}
# collision fix: canned "whole kernel sweet corn" must not enter the FRESH sweet-corn commodity
$sc = $commods | Where-Object { $_.id -eq 'sweet-corn' } | Select-Object -First 1
if ($sc -and (@($sc.exclude) -notcontains 'kernel')) { $sc.exclude = @($sc.exclude) + @('kernel') }
ConvertTo-Json @($commods) -Depth 6 | Set-Content $cf -Encoding UTF8
Write-Output ("commodities.json: +" + $added + " -> " + @($commods).Count + " total")

# ---- categories.json ----
$catf = Join-Path $root 'categories.json'
$cats = Get-Content $catf -Raw | ConvertFrom-Json
$catList = [System.Collections.ArrayList]@($cats.categories)
$newCatMeta = @{ bakery = @{ order = 5; label = 'Bread & Bakery' }; snacks = @{ order = 7; label = 'Snacks & Drinks' }; frozen = @{ order = 8; label = 'Frozen' } }
# shift: pantry -> 6, household -> 9
foreach ($c in $catList) { if ($c.key -eq 'pantry') { $c.order = 6 }; if ($c.key -eq 'household') { $c.order = 9 } }
foreach ($k in $src.categories.PSObject.Properties.Name) {
  $ids = @($src.categories.$k)
  $cat = $catList | Where-Object { $_.key -eq $k } | Select-Object -First 1
  if (-not $cat) {
    $meta = $newCatMeta[$k]
    $cat = [pscustomobject]@{ order = $meta.order; key = $k; label = $meta.label; commodities = @() }
    [void]$catList.Add($cat)
  }
  foreach ($id in $ids) { if (@($cat.commodities) -notcontains $id) { $cat.commodities = @($cat.commodities) + @($id) } }
}
# move bread from pantry to the new bakery category (bread belongs with tortillas/buns/bagels)
$pantry = $catList | Where-Object { $_.key -eq 'pantry' } | Select-Object -First 1
$bakery = $catList | Where-Object { $_.key -eq 'bakery' } | Select-Object -First 1
if ($pantry -and $bakery -and (@($pantry.commodities) -contains 'bread')) {
  $pantry.commodities = @($pantry.commodities | Where-Object { $_ -ne 'bread' })
  if (@($bakery.commodities) -notcontains 'bread') { $bakery.commodities = @('bread') + @($bakery.commodities) }
}
$cats.categories = @($catList | Sort-Object order)
$cats | ConvertTo-Json -Depth 5 | Set-Content $catf -Encoding UTF8
Write-Output ("categories.json: " + (@($catList) | ForEach-Object { $_.key + '(' + @($_.commodities).Count + ')' }) -join ' ')

# ---- commodity-search.json ----
$tf = Join-Path $root 'commodity-search.json'
$tdoc = Get-Content $tf -Raw | ConvertFrom-Json
$tAdded = 0
foreach ($k in $src.terms.PSObject.Properties.Name) {
  if (-not $tdoc.terms.PSObject.Properties[$k]) { $tdoc.terms | Add-Member -NotePropertyName $k -NotePropertyValue ([string]$src.terms.$k); $tAdded++ }
}
$tdoc | ConvertTo-Json -Depth 4 | Set-Content $tf -Encoding UTF8
Write-Output ("commodity-search.json: +" + $tAdded + " terms")
