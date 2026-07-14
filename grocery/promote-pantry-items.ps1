<#
  promote-pantry-items.ps1

  We already price ~165 "recipe-only" commodities (Cornstarch, Tomato Paste, spices...) in
  product-urls.json for the recipe costing, but compare-deals prices the BOARD from each
  store's out\regular\<store>-regular-<date>.json product list. So a recipe price is invisible
  to the board until its store product row exists in that store's regular file.

  This lifts those already-verified per-store products into the regular files under the new
  board commodity ids, so the board can price them without re-pulling.

  IMPORTANT: compare-deals takes only the NEWEST regular file per store, so we must write a new
  dated file containing ALL prior rows plus the new ones - never just the new ones.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$today = '2026-07-14'

# recipe-set commodity name  ->  new board commodity id
$MAP = @{
  'Cornstarch'          = 'cornstarch'
  'Bread Crumbs'        = 'bread-crumbs'
  'Panko Breadcrumbs'   = 'bread-crumbs'
  'Paprika'             = 'paprika'
  'Dried Oregano'       = 'dried-oregano'
  'Dried Parsley'       = 'dried-parsley'
  'Ground Cinnamon'     = 'ground-cinnamon'
  'Ground Turmeric'     = 'ground-turmeric'
  'Red Pepper Flakes'   = 'red-pepper-flakes'
  'Garlic Powder'       = 'garlic-powder'
  'Onion Powder'        = 'onion-powder'
  'Chili Powder'        = 'chili-powder'
  'Ground Cumin'        = 'ground-cumin'
  'Italian Seasoning'   = 'italian-seasoning'
  'Chickpeas'           = 'chickpeas'
  'Kidney Beans'        = 'kidney-beans'
  'Crushed Tomatoes'    = 'crushed-tomatoes'
  'Tomato Paste'        = 'tomato-paste'
  'Tomato Sauce'        = 'tomato-sauce'
  'Soy Sauce'           = 'soy-sauce'
  'White Vinegar'       = 'white-vinegar'
  'Lemon Juice'         = 'lemon-juice'
}

# store -> the regular-file basename prefix used in out\regular
$STOREFILE = @{
  'Aldi'         = 'aldi'
  'Walmart'      = 'walmart'
  'Hy-Vee'       = 'hyvee'
  "Baker's"      = 'bakers'
  'Family Fare'  = 'family-fare'
  'Fareway'      = 'fareway'
  "Sam's Club"   = 'sams'
}

$pu = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items
$regDir = Join-Path $root 'out\regular'

# collect the new rows we want to add, grouped by store
$newRows = @{}
foreach ($store in $STOREFILE.Keys) { $newRows[$store] = New-Object System.Collections.ArrayList }

foreach ($c in $pu.PSObject.Properties) {
  $name = [string]$c.Value.commodity
  if (-not $MAP.ContainsKey($name)) { continue }
  foreach ($store in $STOREFILE.Keys) {
    $e = $c.Value.$store
    if (-not $e -or -not $e.price -or -not $e.name) { continue }
    [void]$newRows[$store].Add([ordered]@{
      store     = $store
      item      = [string]$e.name
      ad_price  = ('$' + ([double]$e.price).ToString('0.00'))
      size      = [string]$e.size
      regular   = $null
      source_ad = "promoted from verified recipe pricing ($name)"
    })
  }
}

foreach ($store in $STOREFILE.Keys) {
  $prefix = $STOREFILE[$store]
  $rows   = $newRows[$store]
  if ($rows.Count -eq 0) { Write-Output ("  {0,-12} no promotable rows" -f $store); continue }

  # newest existing regular file for this store (may not exist, e.g. Sam's)
  $existing = Get-ChildItem (Join-Path $regDir ($prefix + '-regular-*.json')) -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending | Select-Object -First 1

  if ($existing) {
    $doc = Get-Content $existing.FullName -Raw | ConvertFrom-Json
    $all = New-Object System.Collections.ArrayList
    foreach ($d in $doc.deals) { [void]$all.Add($d) }
    $have = @($doc.deals | ForEach-Object { [string]$_.item })
    $added = 0
    foreach ($r in $rows) { if ($have -notcontains $r.item) { [void]$all.Add($r); $added++ } }
    $doc.deals = $all.ToArray()
    $out = Join-Path $regDir ($prefix + '-regular-' + $today + '.json')
    ($doc | ConvertTo-Json -Depth 6) | Set-Content $out -Encoding UTF8
    $total = @($doc.deals).Count
    Write-Output ("  {0,-12} {1} -> {2} rows (+{3} promoted)  [{4}]" -f $store, ($total - $added), $total, $added, (Split-Path $out -Leaf))
  }
  else {
    # no regular file yet (Sam's Club) - create one
    $doc = [ordered]@{
      store         = $store
      week_of       = '2026-07-12'
      price_type    = 'everyday'
      price_mode    = 'in-store'
      mode_verified = $today
      mode_evidence = "Sam's PDP shows club/pickup price separate from shipping; we store the club price"
      source        = 'promoted from verified recipe pricing (product-urls.json)'
      deals         = $rows.ToArray()
    }
    $out = Join-Path $regDir ($prefix + '-regular-' + $today + '.json')
    ($doc | ConvertTo-Json -Depth 6) | Set-Content $out -Encoding UTF8
    Write-Output ("  {0,-12} NEW file with {1} rows  [{2}]" -f $store, $rows.Count, (Split-Path $out -Leaf))
  }
}
