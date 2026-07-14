<#
  pull-ff-brands-batch.ps1 - Config-driven Family Fare brand pull for brand-config.json (batch 2).
  Buckets to the curated brand list + Our Family store brand. Output: out\brands\out-ff-buckets-b.json
  (same {b,s,per} shape as the browser-store bucket files, so assemble reads all stores uniformly).
#>
param(
  [string]$ConfigPath = '',
  [string]$OutPath = ''
)
$ErrorActionPreference='Stop'
$here=$PSScriptRoot
if(-not $ConfigPath){ $ConfigPath = Join-Path $here 'brand-config.json' }
if(-not $OutPath){ $OutPath = Join-Path $here '..\out\brands\out-ff-buckets-b.json' }
$cfg = (Get-Content $ConfigPath -Raw | ConvertFrom-Json).commodities
$storeBrands = @('Our Family','Value Time','ValuTime','Simply Done','Smart Sense','Open Acres','Full Circle','Finest Reserve','Spartan')
$UA=@{ 'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/125 Safari/537.36'; 'Accept'='application/json' }
$ak='family_fare'; $sid='6401'; $b='https://api.freshop.ncrcloud.com/1'

function Get-Items($term){
  $uri="$b/products?app_key=$ak&store_id=$sid&q="+[uri]::EscapeDataString($term)+"&limit=60&fields=name,brand,size,price,base_price"
  # retry on error OR empty (Freshop throttles rapid runs by returning 200 + 0 items)
  for($t=0;$t -lt 4;$t++){
    try { $items=@((Invoke-RestMethod -Uri $uri -Headers $UA -TimeoutSec 25).items); if($items.Count -gt 0){ return $items } } catch {}
    Start-Sleep -Milliseconds (700 + 500*$t)
  }
  return @()
}
function Parse-Qty([string]$size,[string]$unit){
  if(-not $size){ return 0 }
  $m=[regex]::Match($size.ToLower(),'([\d]+(?:\.[\d]+)?)\s*(fl\s?oz|floz|oz|lbs?|pound|g|kg|ml|l|liter|litre|qt|gal)')
  if(-not $m.Success){ return 0 }
  $n=[double]$m.Groups[1].Value; $u=$m.Groups[2].Value -replace '\s',''
  switch($unit){
    'oz'   { switch -regex ($u){ '^oz$' {return $n} '^(lbs?|pound)$' {return $n*16} '^kg$' {return $n*35.274} '^g$' {return $n*0.035274} default {return 0} } }
    'floz' { switch -regex ($u){ '^(floz|foz)$' {return $n} '^oz$' {return $n} '^(l|liter|litre)$' {return $n*33.814} '^ml$' {return $n*0.033814} '^qt$' {return $n*32} '^gal$' {return $n*128} default {return 0} } }
  }
  return 0
}
function Strip([string]$s){ ($s.ToLower() -replace "[^a-z0-9 ]",'') }

$out=[ordered]@{ store='Family Fare'; generated=(Get-Date -Format 'yyyy-MM-dd'); items=[ordered]@{} }
foreach($cid in $cfg.PSObject.Properties.Name){
  $c=$cfg.$cid
  $raw=@(); foreach($q in @($c.queries)){ $raw += Get-Items $q; Start-Sleep -Milliseconds 450 }
  $seen=@{}; $prods=@()
  foreach($it in $raw){ $k=([string]$it.name+'|'+[string]$it.size); if(-not $seen.ContainsKey($k)){ $seen[$k]=$true; $prods+=$it } }
  $buckets=@{}
  foreach($it in $prods){
    $name=[string]$it.name; if(-not $name){ continue }
    if($c.include -and ($name -notmatch $c.include)){ continue }
    if($c.exclude -and ($name -match $c.exclude)){ continue }
    $val = if($it.base_price){ [double]$it.base_price } elseif($it.price){ [double](([string]$it.price) -replace '[^\d.]','') } else { 0 }
    if($val -le 0){ continue }
    $qty = Parse-Qty ([string]$it.size) ([string]$c.unit); if($qty -le 0){ continue }
    $per=[math]::Round($val/$qty,4)
    # brand match
    $ns=Strip $name; $bn=Strip ([string]$it.brand)
    $brand=$null; $isStore=$false
    foreach($sb in $storeBrands){ if($ns -match [regex]::Escape((Strip $sb))){ $brand='Store brand'; $isStore=$true; break } }
    if(-not $brand){ foreach($cb in @($c.brands)){ if($cb -eq 'Great Value'){ continue }; $cbs=Strip $cb; if($ns -match ('\b'+[regex]::Escape($cbs)) -or $bn -match [regex]::Escape($cbs)){ $brand=$cb; break } } }
    if(-not $brand){ continue }
    if(-not $buckets.ContainsKey($brand) -or $per -lt $buckets[$brand].per){ $buckets[$brand]=[ordered]@{ b=$brand; s=[int][bool]$isStore; per=$per } }
  }
  $out.items[$cid]=@($buckets.Values | Sort-Object per)
  Write-Output ("{0,-22} {1} brands" -f $cid, $buckets.Count)
}
($out | ConvertTo-Json -Depth 8) | Set-Content $OutPath -Encoding UTF8
Write-Output ("`n-> " + $OutPath)