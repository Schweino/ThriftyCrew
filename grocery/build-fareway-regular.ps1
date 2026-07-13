<#
  build-fareway-regular.ps1 - turns the Fareway STOREFRONT extracts (shop.fareway.com, no-markup in-store
  prices, Omaha) into an engine-ready everyday-price file: out\regular\fareway-regular-<date>.json.
  compare-deals.ps1 auto-discovers out\regular\<store>-regular-*.json (price_type=everyday) with NO code
  change, so writing this file is all it takes to put Fareway's current shelf prices into the comparison.

  Input: one or more raw extract files (default: out\fareway\fareway-shop-*.json), each a JSON array of
  { id, name, price, per, orig, unit, size } as produced by the browser DOM extractor. For each commodity id
  we emit the engine's {store,item,ad_price,size,regular} using the store's existing unit conventions:
    - weighted goods (unit like "$4.99/lb")  -> ad_price="$4.99", size="lb"   (per-unit price)
    - "$X per pound"                          -> ad_price="$X",    size="lb"
    - sold each (per="each", no /lb)          -> ad_price="$X",    size="each"
    - packaged                                -> ad_price="$price",size=<package size>
    - milk  -> size "gallon"     (1-gal pack price is per gallon)
    - eggs  -> size "dozen"      (per-dozen price computed from the count)
  Last writer wins per id (pass core first, then the rest). Skips NOT FOUND / empty-price rows.
#>
param([string[]]$In = @(), [string]$OutDir = "", [string]$Today = "")
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$asofS = if ($Today) { $Today } else { (Get-Date).ToString('yyyy-MM-dd') }
if (-not $In -or $In.Count -eq 0) {
  $In = @(Get-ChildItem (Join-Path $OutDir 'fareway\fareway-shop-*.json') -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.FullName })
}
$commod = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
$validSet = @{}; $unitMap = @{}; $pintMap = @{}; foreach ($c in $commod) { $validSet[[string]$c.id] = $true; $unitMap[[string]$c.id] = [string]$c.unit; if ($c.PSObject.Properties['pint_oz'] -and $c.pint_oz) { $pintMap[[string]$c.id] = [double]$c.pint_oz } }

$byId = [ordered]@{}
$byUrl = [ordered]@{}
foreach ($f in $In) {
  if (-not (Test-Path $f)) { continue }
  foreach ($r in (Get-Content $f -Raw | ConvertFrom-Json)) {
    $id = [string]$r.id
    if (-not $validSet.ContainsKey($id)) { continue }
    $name = [string]$r.name
    if (-not $name -or $name -match 'NOT FOUND') { continue }
    $price = [string]$r.price; if (-not $price) { continue }
    $per = ([string]$r.per).ToLower()
    $unit = [string]$r.unit
    $size = [string]$r.size
    $adp = ''; $sz = ''
    $um = [regex]::Match($unit, '\$?\s*([\d.]+)\s*/\s*(lb|oz|gal|kg|ct|ea|each|pound)')
    if ($um.Success) {
      $adp = '$' + $um.Groups[1].Value
      $u = $um.Groups[2].Value; if ($u -eq 'pound') { $u = 'lb' }; if ($u -eq 'ea') { $u = 'each' }
      $sz = $u
    } elseif ($per -eq 'pound') { $adp = '$' + $price; $sz = 'lb' }
      elseif ($per -eq 'each')  { $adp = '$' + $price; $sz = 'each' }
      else { $adp = '$' + $price; $sz = $size }
    # canonical-unit fixups so the engine can price the item in the commodity's unit
    $cu = if ($unitMap.ContainsKey($id)) { $unitMap[$id] } else { '' }
    if ($cu -eq 'each') {
      # a loaf / avocado / ear / whole melon = one each; the current price IS the per-each price.
      # BUT a counted pack ("12 ct" buns/popsicles/tampons) must KEEP its count so the engine divides
      # to a true per-item price - force-writing 'each' here made $3.99/12ct read as $3.99 PER ITEM.
      if ($size -match '\d+\s*ct\b') { $sz = $size }
      else { $sz = 'each' }
      if ($adp -notmatch '^\$[0-9.]+$') { $adp = '$' + $price }
    } elseif ($cu -eq 'gallon') { $sz = 'gallon' }
      elseif ($cu -eq 'dozen') {
        $ct = [regex]::Match($size, '([\d.]+)\s*ct')
        if ($ct.Success) { $n=[double]$ct.Groups[1].Value; if ($n -gt 0) { $adp = '$' + ([math]::Round([double]$price / ($n/12), 2)); $sz = 'dozen' } }
        else { $sz = 'dozen' }
      }
    # by-VOLUME container -> canonical dry weight: a fresh-berry "pint" is a dry clamshell with no weight on the
    # label, so normalize it to the commodity's declared pint_oz (blueberries = 11.2 oz, US retail standard). This
    # makes BOTH the board price and the "See item" link size a real weight, so it prices per-ounce like the
    # 18-oz clamshells and the link's per-unit matches the board by construction. Only bare pints, never a size
    # that already states a weight.
    if ($pintMap.ContainsKey($id) -and ($sz.ToLower() -match '\b(pt|pint)s?\b') -and ($sz.ToLower() -notmatch '\b(oz|ounce|ounces|lb|lbs|pound|pounds|gram|grams|\bg\b|ml|liter|litre)\b')) {
      $pnM = [regex]::Match($sz.ToLower(), '(\d+(?:\.\d+)?)\s*(?:pt|pint)s?\b'); $pn = if ($pnM.Success) { [double]$pnM.Groups[1].Value } else { 1 }
      $sz = ('{0} oz' -f ($pn * $pintMap[$id]))
    }
    $reg = if ($r.orig -and "$($r.orig)" -ne '') { '$' + [string]$r.orig } else { '' }
    $byId[$id] = [ordered]@{ store='Fareway'; item=$name; ad_price=$adp; size=$sz; regular=$reg; source_ad='shop.fareway.com' }
    # emit the product-URL input using the SAME price+size the board uses, so the "See item" link's per-unit
    # equals the board per-unit by construction (a Fareway price can never render without a matching link).
    if ($r.url -and "$($r.url)" -ne '') { $byUrl[$id] = [ordered]@{ id=$id; url=[string]$r.url; price=($adp -replace '[^0-9.]',''); size=$sz; name=$name } }
  }
}
$deals = @($byId.Values)
$doc = [ordered]@{ store='Fareway'; price_type='everyday'; source='shop.fareway.com (Instacart Storefront, no-markup in-store prices, Omaha)'; generated=$asofS; deals=$deals }
$regDir = Join-Path $OutDir 'regular'
New-Item -ItemType Directory -Force -Path $regDir | Out-Null
$doc | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $regDir "fareway-regular-$asofS.json") -Encoding UTF8
# product-URL input for merge-product-urls.ps1 (store key 'fareway'): every priced Fareway cell that has a
# storefront product page gets a link whose price+size match the board exactly.
$urlRows = @($byUrl.Values)
if ($urlRows.Count) {
  $uiDir = Join-Path $OutDir 'url-inputs'; New-Item -ItemType Directory -Force -Path $uiDir | Out-Null
  ($urlRows | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $uiDir 'store-fareway1-urls.json') -Encoding UTF8
  Write-Output ("store-fareway1-urls.json: $($urlRows.Count) Fareway product links")
}
Write-Output ("fareway-regular-$asofS.json: $($deals.Count) commodities")
$deals | ForEach-Object { "  {0,-20} {1,-8} {2}" -f $_.item.Substring(0,[Math]::Min(20,$_.item.Length)), $_.ad_price, $_.size }
