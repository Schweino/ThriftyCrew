$ErrorActionPreference='Stop'
$here='C:\Codex\income\grocery\brands'
$ff = Get-Content (Join-Path $here '..\out\brands\ff-brands.json') -Raw | ConvertFrom-Json
$wm = Get-Content (Join-Path $here 'out-walmart-buckets.json') -Raw | ConvertFrom-Json
$sm = Get-Content (Join-Path $here 'out-sams-buckets.json') -Raw | ConvertFrom-Json
$bk = Get-Content (Join-Path $here 'out-bakers-buckets.json') -Raw | ConvertFrom-Json
$hv = Get-Content (Join-Path $here 'out-hyvee-buckets.json') -Raw | ConvertFrom-Json

# pilot item id -> board commodity id + display label + unit
$map = @{
  'peanut-butter'    =@{ board='peanut-butter';     label='Peanut Butter';   unit='oz' }
  'ketchup'          =@{ board='ketchup';           label='Ketchup';         unit='oz' }
  'mayonnaise'       =@{ board='mayonnaise';        label='Mayonnaise';      unit='fl oz' }
  'ground-coffee'    =@{ board='coffee';            label='Ground Coffee';   unit='oz' }
  'cream-cheese'     =@{ board='cream-cheese';      label='Cream Cheese';    unit='oz' }
  'laundry-detergent'=@{ board='laundry-detergent';label='Laundry Detergent';unit='fl oz' }
  'cereal-honey-oat' =@{ board='cereal';            label='Honey Nut Cereal';unit='oz' }
  'cola-2l'          =@{ board='soda';              label='Cola';            unit='fl oz' }
  'ranch-dressing'   =@{ board='ranch-dressing';    label='Ranch Dressing';  unit='fl oz' }
  'shredded-cheddar' =@{ board='shredded-cheese';   label='Shredded Cheddar';unit='oz' }
}
$storeOrder = @('Family Fare','Walmart',"Sam's Club","Baker's",'Hy-Vee')

function Canon([string]$b){
  $k=([regex]::Replace($b.ToLower(),'[^a-z0-9]',''))
  switch -regex ($k){
    '^(storebrand|greatvalue|ourfamily|kroger|membersmark|hyvee|thatssmart)$' {return 'store'}
    '^hunts?$' {return 'hunts'} '^(cocacola|coke)$' {return 'cocacola'} '^wishbone$' {return 'wishbone'}
    '^justins?$' {return 'justins'} '^peterpan$' {return 'peterpan'} '^hiddenvalley$' {return 'hiddenvalley'}
    '^maxwellhouse$' {return 'maxwellhouse'} '^(honeynutcheerios|cheerios)$' {return 'cheerios'}
    '^kens?(steakhouse)?$' {return 'kens'} '^dukes?$' {return 'dukes'} '^hellmanns?$' {return 'hellmanns'}
    '^smuckers?$' {return 'smuckers'} '^(armhammer|armandhammer)$' {return 'armhammer'} '^maltomeal$' {return 'maltomeal'}
    default {return $k}
  }
}
$labels=@{ store='Store brand'; hunts="Hunt's"; cocacola='Coca-Cola'; wishbone='Wish-Bone'; justins="Justin's";
  peterpan='Peter Pan'; hiddenvalley='Hidden Valley'; maxwellhouse='Maxwell House'; cheerios='Honey Nut Cheerios';
  kens="Ken's"; dukes="Duke's"; hellmanns="Hellmann's"; smuckers="Smucker's"; armhammer='Arm & Hammer'; maltomeal='Malt-O-Meal';
  jif='Jif'; skippy='Skippy'; heinz='Heinz'; delmonte='Del Monte'; folgers='Folgers'; starbucks='Starbucks'; dunkin='Dunkin';
  bustelo='Cafe Bustelo'; community='Community'; eighto="Eight O'Clock"; philadelphia='Philadelphia'; kraft='Kraft';
  sargento='Sargento'; tillamook='Tillamook'; crystalfarms='Crystal Farms'; tide='Tide'; gain='Gain'; persil='Persil'; purex='Purex';
  pepsi='Pepsi'; chek='Chek' }

# FF map: pilot id -> canon -> {per, store, label}
$ffByItem=@{}
foreach($it in $ff.items){ if($it.type -eq 'variety'){continue}
  $m=@{}; foreach($b in $it.brands){ $c=Canon ([string]$b.brand); if(-not $m.ContainsKey($c) -or [double]$b.per_unit -lt $m[$c].per){ $m[$c]=@{per=[double]$b.per_unit;store=[bool]$b.is_store_brand;label=[string]$b.brand} } }
  $ffByItem[$it.id]=$m }
function BucketMap($obj){ $r=@{}; foreach($p in $obj.items.PSObject.Properties){ $m=@{}; foreach($b in $p.Value){ if($null -eq $b.per){continue}; $c=Canon ([string]$b.b); if(-not $m.ContainsKey($c) -or [double]$b.per -lt $m[$c].per){ $m[$c]=@{per=[double]$b.per;store=[bool]$b.s} } }; $r[$p.Name]=$m }; return $r }
$wmB=BucketMap $wm; $smB=BucketMap $sm; $bkB=BucketMap $bk; $hvB=BucketMap $hv
$storeData=@{ 'Family Fare'=$ffByItem; 'Walmart'=$wmB; "Sam's Club"=$smB; "Baker's"=$bkB; 'Hy-Vee'=$hvB }

$out=[ordered]@{}
foreach($itemId in $map.Keys){
  $info=$map[$itemId]
  # union of canon brands across stores
  $keys=@()
  foreach($st in $storeOrder){ $sd=$storeData[$st]; if($sd.ContainsKey($itemId)){ $keys += @($sd[$itemId].Keys) } }
  $keys=@($keys | Select-Object -Unique)
  $brands=@()
  foreach($c in $keys){
    $prices=[ordered]@{}; $vals=@(); $isStore=$false; $lbl=$null
    foreach($st in $storeOrder){ $sd=$storeData[$st]
      if($sd.ContainsKey($itemId) -and $sd[$itemId].ContainsKey($c)){ $v=[math]::Round([double]$sd[$itemId][$c].per,3); $prices[$st]=$v; $vals+=$v; if($sd[$itemId][$c].store){$isStore=$true}; if(-not $lbl -and $sd[$itemId][$c].label){$lbl=$sd[$itemId][$c].label} } }
    if($vals.Count -eq 0){ continue }
    # sanity gate: with >=3 store values, drop any outside [0.3x, 4x] of the median
    if($vals.Count -ge 3){ $sorted=@($vals|Sort-Object); $med=$sorted[[int]([math]::Floor($sorted.Count/2))]
      $keep=[ordered]@{}; foreach($k in $prices.Keys){ $v=$prices[$k]; if($v -ge 0.3*$med -and $v -le 4*$med){ $keep[$k]=$v } }; $prices=$keep; $vals=@($prices.Values) }
    if($vals.Count -eq 0){ continue }
    $label = if($labels.ContainsKey($c)){ $labels[$c] } elseif($lbl){ $lbl } else { (Get-Culture).TextInfo.ToTitleCase($c) }
    $min = ($vals | Measure-Object -Minimum).Minimum
    $cheapStore = ($prices.GetEnumerator() | Where-Object { $_.Value -eq $min } | Select-Object -First 1).Key
    $brands += ,([ordered]@{ label=$label; store=$isStore; min=$min; cheapest=$cheapStore; prices=$prices })
  }
  $brands=@($brands | Sort-Object { $_.min })
  if($brands.Count -eq 0){ continue }
  $storesWithData=@($storeOrder | Where-Object { $s=$_; ($brands | Where-Object { $_.prices.Contains($s) }).Count -gt 0 })
  $out[$info.board]=[ordered]@{ label=$info.label; unit=$info.unit; stores=$storesWithData; brands=$brands }
}
$doc=[ordered]@{ generated=(Get-Date -Format 'yyyy-MM-dd'); store_order=$storeOrder; commodities=$out }
($doc | ConvertTo-Json -Depth 9 -Compress) | Set-Content (Join-Path $here '..\out\brands\brands-board.json') -Encoding UTF8
Write-Output ("brands-board: " + $out.Keys.Count + " commodities")
foreach($cid in $out.Keys){ $c=$out[$cid]; Write-Output ("  {0,-18} {1} brands across {2} stores" -f $cid, $c.brands.Count, $c.stores.Count) }