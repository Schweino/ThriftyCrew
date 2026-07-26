<#
  pull-ff-brands.ps1 - BRAND PILOT (Family Fare / Freshop, Omaha store 6401).
  For each pilot item, pulls the shelf catalog, buckets products by BRAND (brand items) or
  VARIETY (produce items), applies the item's exclude regex to drop clearly-different variants,
  parses size -> per-unit price, and keeps the cheapest flagship SKU per brand/variety.
  Output: out\brands\ff-brands.json  (real base_price shelf prices; NEVER fabricated).
#>
$ErrorActionPreference='Stop'
$here = $PSScriptRoot
$root = Split-Path $here -Parent
$cfg  = Get-Content (Join-Path $here 'pilot-items.json') -Raw | ConvertFrom-Json
$UA=@{ 'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/125 Safari/537.36'; 'Accept'='application/json' }
$ak='family_fare'; $sid='6401'; $b='https://api.freshop.ncrcloud.com/1'
$store='Family Fare'
$storeBrands = @($cfg.storeBrands.$store)
$brandMap = $cfg.brandMap
$stripWords = [string]$cfg.stripBrandWords

function Get-FreshopItems($term){
  $uri = "$b/products?app_key=$ak&store_id=$sid&q=" + [uri]::EscapeDataString($term) + "&limit=60&fields=name,brand,size,price,base_price,unit_price"
  for($try=0;$try -lt 2;$try++){
    try { $r = Invoke-RestMethod -Uri $uri -Headers $UA -TimeoutSec 25; return @($r.items) } catch { Start-Sleep -Milliseconds 600 }
  }
  return @()
}
# size string -> quantity in the item's unit basis (oz weight / floz volume / lb). 0 if unparseable.
function Parse-Qty([string]$size,[string]$unit){
  if(-not $size){ return 0 }
  $s = $size.ToLower()
  $m = [regex]::Match($s, '([\d]+(?:\.[\d]+)?)\s*(fl\s?oz|floz|oz|lbs?|pound|g|kg|ml|l|liter|litre|qt|gal)')
  if(-not $m.Success){ return 0 }
  $n = [double]$m.Groups[1].Value; $u = $m.Groups[2].Value -replace '\s',''
  switch($unit){
    'oz'   { switch -regex ($u){ '^(oz)$' {return $n} '^(lbs?|pound)$' {return $n*16} '^kg$' {return $n*35.274} '^g$' {return $n*0.035274} default {return 0} } }
    'floz' { switch -regex ($u){ '^(floz|f\s?oz)$' {return $n} '^oz$' {return $n} '^(l|liter|litre)$' {return $n*33.814} '^ml$' {return $n*0.033814} '^qt$' {return $n*32} '^gal$' {return $n*128} default {return 0} } }
    'lb'   { switch -regex ($u){ '^(lbs?|pound)$' {return $n} '^oz$' {return $n/16} '^kg$' {return $n*2.20462} default {return 0} } }
  }
  return 0
}
function Title-Case([string]$s){ if(-not $s){return ''}; (Get-Culture).TextInfo.ToTitleCase($s.ToLower().Trim()) }
# canonical brand: prefer brand field; else first 2 words of name. normalize casing + a few aliases.
function Norm-Brand([string]$brand,[string]$name){
  $raw = if($brand){ $brand } else { ($name -split '\s+' | Select-Object -First 2) -join ' ' }
  $t = Title-Case $raw
  if($stripWords){ for($k=0;$k -lt 2;$k++){ $t = ($t -replace $stripWords,'').Trim() } }
  if($brandMap){ $hit = $brandMap.PSObject.Properties | Where-Object { $_.Name -eq $t } | Select-Object -First 1; if($hit){ $t = [string]$hit.Value } }
  return $t
}
function Is-StoreBrand([string]$brand,[string]$name){
  foreach($sb in $storeBrands){ if(($brand -and $brand -match [regex]::Escape($sb)) -or ($name -match [regex]::Escape($sb))){ return $true } }
  return $false
}

$result = [ordered]@{ store=$store; store_id=$sid; generated=(Get-Date -Format 'yyyy-MM-dd HH:mm'); source='Freshop base_price (Omaha 6401)'; items=@() }

foreach($item in $cfg.items){
  $raw=@()
  foreach($q in @($item.queries)){ $raw += Get-FreshopItems $q; Start-Sleep -Milliseconds 300 }
  # dedupe by name|size
  $seen=@{}; $prods=@()
  foreach($it in $raw){ $k=([string]$it.name+'|'+[string]$it.size); if(-not $seen.ContainsKey($k)){ $seen[$k]=$true; $prods+=$it } }

  $buckets=@{}   # key -> best row
  foreach($it in $prods){
    $name=[string]$it.name; if(-not $name){ continue }
    if($item.include -and ($name -notmatch $item.include)){ continue }
    if($item.exclude -and ($name -match $item.exclude)){ continue }
    $val = if($it.base_price){ [double]$it.base_price } elseif($it.price){ [double](([string]$it.price) -replace '[^\d.]','') } else { 0 }
    if($val -le 0){ continue }
    $qty = Parse-Qty ([string]$it.size) $item.unit
    if($qty -le 0){ continue }
    $per = [math]::Round($val/$qty,4)

    if($item.type -eq 'variety'){
      $key=$null
      foreach($v in @($item.varieties)){ if($name -match ('(?i)'+[regex]::Escape($v))){ $key=$v; break } }
      if(-not $key){ continue }
      $isStore=$false
    } else {
      $key = Norm-Brand ([string]$it.brand) $name
      if(-not $key){ continue }
      $isStore = Is-StoreBrand ([string]$it.brand) $name
      if($isStore){ $key = 'Store brand' }
    }
    if(-not $buckets.ContainsKey($key) -or $per -lt $buckets[$key].per_unit){
      $buckets[$key] = [ordered]@{ brand=$key; is_store_brand=$isStore; name=$name; size=[string]$it.size; price=$val; per_unit=$per }
    }
  }
  $rows = @($buckets.Values | Sort-Object per_unit)
  $result.items += ,([ordered]@{ id=$item.id; label=$item.label; type=$item.type; unit=$item.unit; brand_count=$rows.Count; brands=$rows })
  Write-Output ("{0,-22} {1} brands/varieties" -f $item.label, $rows.Count)
}

$outDir = Join-Path $root 'out\brands'
if(-not (Test-Path $outDir)){ New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$outFile = Join-Path $outDir 'ff-brands.json'
($result | ConvertTo-Json -Depth 8) | Set-Content $outFile -Encoding UTF8
Write-Output ("`n-> " + $outFile)
