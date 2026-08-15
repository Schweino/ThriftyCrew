# Find Family Fare PULL-DROP victims: commodities where FF is missing on the board but the Freshop API
# DOES return a real matching product (so the pull silently dropped it). Read-only diagnosis.
$ErrorActionPreference='Stop'
$root='C:\Codex\ThriftyCrew\grocery'
$tmp=ConvertFrom-Json ([IO.File]::ReadAllText("$root\commodities.json")); $commods=@($tmp)
$byId=@{}; foreach($c in $commods){ $byId[[string]$c.id]=$c }
$terms=(ConvertFrom-Json ([IO.File]::ReadAllText("$root\commodity-search.json"))).terms
$cmp=@((ConvertFrom-Json ([IO.File]::ReadAllText((Get-ChildItem "$root\out\comparison-*.json"|Sort-Object Name -Descending|Select-Object -First 1).FullName))).comparison)
# FF-present set from the board
$ffHas=@{}; foreach($r in $cmp){ foreach($s in $r.stores){ if($s.store -eq 'Family Fare'){ $ffHas[[string]$r.id]=$true } } }
$missing=@($commods | Where-Object { -not $ffHas.ContainsKey([string]$_.id) } | ForEach-Object { [string]$_.id })
Write-Output ("FF-missing commodities to probe: "+$missing.Count)

$ak='family_fare'; $sid='6401'; $b='https://api.freshop.ncrcloud.com/1'; $UA=@{'User-Agent'='Mozilla/5.0'}
function Match-Local($c,$name){
  $n=$name.ToLower()
  $hit=$false; foreach($inc in $c.include){ try{ if($n -match $inc){$hit=$true;break} }catch{} }
  if(-not $hit){ return $false }
  foreach($e in $c.exclude){ try{ if($n -match $e){ return $false } }catch{} }
  return $true
}
$victims=New-Object System.Collections.Generic.List[object]
$noProduct=New-Object System.Collections.Generic.List[string]
foreach($id in $missing){
  $c=$byId[$id]; $term=[string]$terms.$id
  if(-not $term){ $noProduct.Add($id+' (no search term)'); continue }
  $items=@()
  try{ $r=Invoke-RestMethod -Uri ("$b/products?app_key=$ak&store_id=$sid&q="+[uri]::EscapeDataString($term)+"&limit=15&fields=name,size,price,base_price") -Headers $UA -TimeoutSec 25; $items=@($r.items) }catch{}
  Start-Sleep -Milliseconds 350
  # keep products that match this commodity's include/exclude AND have a price
  $good=@($items | Where-Object { $_.name -and (Match-Local $c ([string]$_.name)) -and ($_.base_price -or $_.price) })
  if($good.Count){
    $best=$good[0]; $val=if($best.base_price){$best.base_price}else{$best.price}
    $victims.Add([pscustomobject]@{id=$id;term=$term;name=[string]$best.name;price=$val;size=[string]$best.size})
  } else { $noProduct.Add($id) }
}
Write-Output ("PULL-DROP VICTIMS (FF carries a matching product but the pull missed it): "+$victims.Count)
$victims | ForEach-Object { Write-Output ("  {0,-20} ${1,-7} {2}" -f $_.id, $_.price, $_.name) }
Write-Output ("`nno matching FF product via API (genuinely not carried / no match): "+$noProduct.Count)
$victims | ConvertTo-Json -Depth 4 | Set-Content "$root\out\audit\ff-pulldrop-victims.json" -Encoding UTF8