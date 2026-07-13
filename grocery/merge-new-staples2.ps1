<#
  merge-new-staples2.ps1 - merges new-staples2-{a,b,c}.json (the 200-item expansion) into commodities.json /
  categories.json / commodity-search.json, PLUS cross-guard fixups on EXISTING rules so old broad includes
  don't steal the new commodities' products (bread vs french-bread etc). Idempotent.
#>
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

$cf = Join-Path $root 'commodities.json'
$tmp = ConvertFrom-Json ([IO.File]::ReadAllText($cf)); $commods = [System.Collections.ArrayList]@($tmp)
$have = @{}; foreach ($c in $commods) { $have[[string]$c.id] = $true }

$catf = Join-Path $root 'categories.json'
$cats = ConvertFrom-Json ([IO.File]::ReadAllText($catf))
$catList = [System.Collections.ArrayList]@($cats.categories)
$newCatMeta = @{ personal = @{ order = 10; label = 'Personal Care' }; baby = @{ order = 11; label = 'Baby' }; pet = @{ order = 12; label = 'Pet' } }

$tf = Join-Path $root 'commodity-search.json'
$tdoc = ConvertFrom-Json ([IO.File]::ReadAllText($tf))

$added = 0; $tAdded = 0
foreach ($src in @('new-staples2-a.json','new-staples2-b.json','new-staples2-c.json')) {
  $doc = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root $src)))
  foreach ($n in $doc.commodities) { if (-not $have.ContainsKey([string]$n.id)) { [void]$commods.Add($n); $have[[string]$n.id] = $true; $added++ } }
  foreach ($k in $doc.categories.PSObject.Properties.Name) {
    $cat = $catList | Where-Object { $_.key -eq $k } | Select-Object -First 1
    if (-not $cat) { $meta = $newCatMeta[$k]; $cat = [pscustomobject]@{ order = $meta.order; key = $k; label = $meta.label; commodities = @() }; [void]$catList.Add($cat) }
    foreach ($id in @($doc.categories.$k)) { if (@($cat.commodities) -notcontains $id) { $cat.commodities = @($cat.commodities) + @($id) } }
  }
  foreach ($k in $doc.terms.PSObject.Properties.Name) {
    if (-not $tdoc.terms.PSObject.Properties[$k]) { $tdoc.terms | Add-Member -NotePropertyName $k -NotePropertyValue ([string]$doc.terms.$k); $tAdded++ }
  }
}

# ---- cross-guards: keep EXISTING broad includes from stealing the new commodities' products ----
function AddExcl([string]$id, [string[]]$pats) {
  $c = $commods | Where-Object { $_.id -eq $id } | Select-Object -First 1
  if (-not $c) { return }
  foreach ($p in $pats) { if (@($c.exclude) -notcontains $p) { $c.exclude = @($c.exclude) + @($p) } }
}
AddExcl 'bread'          @('french', 'baguette', 'italian\s+bread', 'texas\s+toast')
AddExcl 'coffee'         @('instant')
AddExcl 'apples'         @('\bjuice\b', '\bsauce\b', '\bcider\b', '\bcup\b', '\bcanned\b')
AddExcl 'grapes'         @('\bjuice\b', '\bfrozen\b', '\bjelly\b')
AddExcl 'strawberries'   @('\bfrozen\b')
AddExcl 'blueberries'    @('\bfrozen\b')
AddExcl 'peaches'        @('\bcanned\b', '\bcup\b', 'syrup')
AddExcl 'onions'         @('green\s+onion', 'scallion', '\bfrozen\b', '\brings\b', 'french\s+fried')
AddExcl 'salmon'         @('pink\s+salmon', '\bcans?\b', 'bumble\s*bee', 'chicken\s+of\s+the\s+sea')
AddExcl 'storage-bags'   @('\bsandwich\b', 'snack\s+bags?')
AddExcl 'broccoli'       @('steam', '\bcuts\b')
AddExcl 'sweet-corn'     @('\bfrozen\b')
AddExcl 'milk'           @('\ba2\b', 'lactose')
AddExcl 'bananas'        @('bread', 'chips', '\bfrozen\b', 'pudding')
AddExcl 'watermelon'     @('chunks', '\bcup\b', '\bdrink\b', '\bjuice\b')
AddExcl 'hot-dogs'       @('corn\s*dogs?')
AddExcl 'pasta'          @('lasagna', 'egg\s+noodle')
AddExcl 'ground-beef-8020' @('\bjerky\b')
AddExcl 'oatmeal'        @('\bcream\s+pie\b')
AddExcl 'shredded-cheese' @('string')

ConvertTo-Json @($commods) -Depth 6 | Set-Content $cf -Encoding UTF8
$cats.categories = @($catList | Sort-Object order)
$cats | ConvertTo-Json -Depth 5 | Set-Content $catf -Encoding UTF8
$tdoc | ConvertTo-Json -Depth 4 | Set-Content $tf -Encoding UTF8
Write-Output ("commodities: +" + $added + " -> " + @($commods).Count + " | terms: +" + $tAdded + " | categories: " + ((@($catList) | Sort-Object order | ForEach-Object { $_.key + '(' + @($_.commodities).Count + ')' }) -join ' '))
