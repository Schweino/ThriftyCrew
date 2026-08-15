$ErrorActionPreference='Stop'
$here='C:\Codex\ThriftyCrew\grocery\brands'
$cfg = (Get-Content (Join-Path $here 'brand-config-10.json') -Raw | ConvertFrom-Json).commodities
$ff = (Get-Content (Join-Path $here '..\out\brands\out-ff-buckets-j.json') -Raw | ConvertFrom-Json).items
$wm = (Get-Content (Join-Path $here '..\out\brands\out-walmart-buckets-j.json') -Raw | ConvertFrom-Json).items
$sm = (Get-Content (Join-Path $here '..\out\brands\out-sams-buckets-j.json') -Raw | ConvertFrom-Json).items
$bk = (Get-Content (Join-Path $here '..\out\brands\out-bakers-buckets-j.json') -Raw | ConvertFrom-Json).items
$hv = (Get-Content (Join-Path $here '..\out\brands\out-hyvee-buckets-j.json') -Raw | ConvertFrom-Json).items
$bb = Get-Content (Join-Path $here '..\out\brands\brands-board.json') -Raw | ConvertFrom-Json
$storeOrder = @('Family Fare','Walmart',"Sam's Club","Baker's",'Hy-Vee')
$storeData = @{ 'Family Fare'=$ff; 'Walmart'=$wm; "Sam's Club"=$sm; "Baker's"=$bk; 'Hy-Vee'=$hv }

function BrandMap($obj,$cid){ $m=@{}; if($obj.$cid){ foreach($r in @($obj.$cid)){ if($null -eq $r.per){continue}; $k=[string]$r.b; if(-not $m.ContainsKey($k) -or [double]$r.per -lt $m[$k].per){ $m[$k]=@{per=[double]$r.per; store=([string]$r.b -eq 'Store brand')} } } }; return $m }

$added=0
foreach($cid in $cfg.PSObject.Properties.Name){
  $info=$cfg.$cid
  $maps=@{}; foreach($st in $storeOrder){ $maps[$st]=BrandMap $storeData[$st] $cid }
  $keys=@(); foreach($st in $storeOrder){ $keys += @($maps[$st].Keys) }; $keys=@($keys | Select-Object -Unique)
  $brands=@()
  foreach($k in $keys){
    $prices=[ordered]@{}; $vals=@(); $isStore=$false
    foreach($st in $storeOrder){ if($maps[$st].ContainsKey($k)){ $v=[math]::Round($maps[$st][$k].per,3); $prices[$st]=$v; $vals+=$v; if($maps[$st][$k].store){$isStore=$true} } }
    if($vals.Count -eq 0){ continue }
    # sanity gate: with >=3 store values, drop any outside [0.3x, 4x] of the median (catches size/parse errors)
    if($vals.Count -ge 3){ $sorted=@($vals|Sort-Object); $med=$sorted[[int]([math]::Floor($sorted.Count/2))]
      $keep=[ordered]@{}; foreach($sk in $prices.Keys){ $v=$prices[$sk]; if($v -ge 0.3*$med -and $v -le 4*$med){ $keep[$sk]=$v } }; $prices=$keep; $vals=@($prices.Values) }
    if($vals.Count -eq 0){ continue }
    $min=($vals|Measure-Object -Minimum).Minimum
    $cheap=($prices.GetEnumerator() | Where-Object { $_.Value -eq $min } | Select-Object -First 1).Key
    $brands += ,([ordered]@{ label=$k; store=[bool]$isStore; min=$min; cheapest=$cheap; prices=$prices })
  }
  $brands=@($brands | Sort-Object { $_.min })
  if($brands.Count -eq 0){ continue }
  $storesWith=@($storeOrder | Where-Object { $s=$_; ($brands | Where-Object { $_.prices.Contains($s) }).Count -gt 0 })
  $node=[ordered]@{ label=[string]$info.label; unit=[string]$info.unit; stores=$storesWith; brands=$brands }
  $bb.commodities | Add-Member -NotePropertyName $cid -NotePropertyValue $node -Force
  $added++
  Write-Output ("{0,-20} {1} brands / {2} stores" -f $cid, $brands.Count, $storesWith.Count)
}
($bb | ConvertTo-Json -Depth 9 -Compress) | Set-Content (Join-Path $here '..\out\brands\brands-board.json') -Encoding UTF8
$total=@($bb.commodities.PSObject.Properties).Count
Write-Output ("`nadded " + $added + " commodities; brands-board now has " + $total + " total")
