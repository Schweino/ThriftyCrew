$ErrorActionPreference='Stop'
$here=$PSScriptRoot
$cfg = (Get-Content (Join-Path $here 'brand-config.json') -Raw | ConvertFrom-Json).commodities
$ff = Get-Content (Join-Path $here '..\out\brands\out-ff-buckets-b.json') -Raw | ConvertFrom-Json
$storeBrands = @('Our Family','Value Time','Simply Done','Open Acres','Full Circle','Finest Reserve','Spartan')
$UA=@{ 'User-Agent'='Mozilla/5.0'; 'Accept'='application/json' }
$ak='family_fare'; $sid='6401'; $b='https://api.freshop.ncrcloud.com/1'
function FetchP($term){ $uri="$b/products?app_key=$ak&store_id=$sid&q="+[uri]::EscapeDataString($term)+"&limit=60&fields=name,brand,size,base_price"
  for($t=0;$t -lt 6;$t++){ try { $x=@((Invoke-RestMethod -Uri $uri -Headers $UA -TimeoutSec 25).items); if($x.Count){ return $x } } catch {}; Start-Sleep -Milliseconds (900+700*$t) }; return @() }
function Strip([string]$s){ ($s.ToLower() -replace "[^a-z0-9 ]",'') }
function PQ([string]$size,[string]$unit){ if(-not $size){return 0}; $m=[regex]::Match($size.ToLower(),'([\d]+(?:\.[\d]+)?)\s*(fl\s?oz|floz|oz|lbs?|pound|kg|ml|l|liter|qt|gal)'); if(-not $m.Success){return 0}; $n=[double]$m.Groups[1].Value; $u=$m.Groups[2].Value -replace '\s',''
  switch($unit){ 'oz' { switch -regex($u){'^oz$'{return $n}'^(lbs?|pound)$'{return $n*16}'^kg$'{return $n*35.274}default{return 0}} } 'floz' { switch -regex($u){'^(floz|foz)$'{return $n}'^oz$'{return $n}'^(l|liter)$'{return $n*33.814}'^ml$'{return $n*0.033814}'^qt$'{return $n*32}'^gal$'{return $n*128}default{return 0}} } }; return 0 }
function Bucket($cid,[string[]]$queries){
  $c=$cfg.$cid; $raw=@(); foreach($q in $queries){ $raw+=FetchP $q; Start-Sleep -Milliseconds 500 }
  Write-Output ("  " + $cid + ": fetched " + $raw.Count + " raw")
  $bk=@{}
  foreach($it in $raw){ $name=[string]$it.name; if(-not $name){continue}
    if($c.include -and ($name -notmatch $c.include)){continue}; if($c.exclude -and ($name -match $c.exclude)){continue}
    $val=if($it.base_price){[double]$it.base_price}else{0}; if($val -le 0){continue}
    $qty=PQ ([string]$it.size) ([string]$c.unit); if($qty -le 0){continue}; $per=[math]::Round($val/$qty,4)
    $ns=Strip $name; $bn=Strip ([string]$it.brand); $brand=$null; $st=$false
    foreach($sb in $storeBrands){ if($ns -match [regex]::Escape((Strip $sb))){ $brand='Store brand'; $st=$true; break } }
    if(-not $brand){ foreach($cb in @($c.brands)){ if($cb -eq 'Great Value'){continue}; $cbs=Strip $cb; if($ns -match ('\b'+[regex]::Escape($cbs)) -or $bn -match [regex]::Escape($cbs)){ $brand=$cb; break } } }
    if(-not $brand){continue}
    if(-not $bk.ContainsKey($brand) -or $per -lt $bk[$brand].per){ $bk[$brand]=[ordered]@{ b=$brand; s=[int][bool]$st; per=$per } }
  }
  return @($bk.Values | Sort-Object per)
}
# ---- sliced-cheese: show raw to assess include ----
Write-Output "SLICED-CHEESE raw (american cheese):"
foreach($it in @((FetchP 'american cheese') | Select-Object -First 12)){ Write-Output ("   b='"+$it.brand+"' n='"+$it.name+"' sz='"+$it.size+"'") }

$pasta = Bucket 'pasta' @('spaghetti','pasta','penne')
$ff.items.pasta = $pasta
Write-Output ("pasta now: " + $pasta.Count + " brands -> " + (($pasta | ForEach-Object { $_.b + ' $' + $_.per }) -join ', '))
($ff | ConvertTo-Json -Depth 8) | Set-Content (Join-Path $here '..\out\brands\out-ff-buckets-b.json') -Encoding UTF8
Write-Output "patched out-ff-buckets-b.json (pasta)"