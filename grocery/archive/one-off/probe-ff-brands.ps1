$ErrorActionPreference='Stop'
$UA=@{ 'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/125 Safari/537.36'; 'Accept'='application/json' }
$ak='family_fare'; $sid='6401'; $b='https://api.freshop.ncrcloud.com/1'
$term = 'peanut butter'
$uri = "$b/products?app_key=$ak&store_id=$sid&q=" + [uri]::EscapeDataString($term) + "&limit=30&fields=name,brand,size,price,base_price,unit_price,unit,uom,department"
$r = Invoke-RestMethod -Uri $uri -Headers $UA -TimeoutSec 25
Write-Output ("returned items: " + @($r.items).Count)
$i=0
foreach($it in @($r.items)){
  $i++
  $val = if($it.base_price){$it.base_price}else{$it.price}
  Write-Output ("[" + $i + "] brand='" + $it.brand + "' | name='" + $it.name + "' | size='" + $it.size + "' | base=" + $it.base_price + " price=" + $it.price + " | unit_price='" + $it.unit_price + "'")
  if($i -ge 22){ break }
}