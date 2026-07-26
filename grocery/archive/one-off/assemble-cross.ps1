$ErrorActionPreference='Stop'
$here='C:\Codex\income\grocery\brands'
$ff = Get-Content (Join-Path $here '..\out\brands\ff-brands.json') -Raw | ConvertFrom-Json
$wm = Get-Content (Join-Path $here 'out-walmart-buckets.json') -Raw | ConvertFrom-Json

function Canon([string]$b){
  $k = ([regex]::Replace($b.ToLower(),'[^a-z0-9]','' ))
  switch -regex ($k){
    '^(storebrand|greatvalue|ourfamily)$' {return 'store'}
    '^hunts?$' {return 'hunts'}
    '^(cocacola|coke)$' {return 'cocacola'}
    '^wishbone$' {return 'wishbone'}
    '^justins?$' {return 'justins'}
    '^peterpan$' {return 'peterpan'}
    '^hiddenvalley$' {return 'hiddenvalley'}
    '^maxwellhouse$' {return 'maxwellhouse'}
    '^(honeynutcheerios|cheerios)$' {return 'cheerios'}
    '^kens?(steakhouse)?$' {return 'kens'}
    '^dukes?$' {return 'dukes'}
    '^hellmanns?$' {return 'hellmanns'}
    '^smuckers?$' {return 'smuckers'}
    '^armhammer$' {return 'armhammer'}
    default {return $k}
  }
}
$labels=@{ store='Store brand'; hunts="Hunt's"; cocacola='Coca-Cola'; wishbone='Wish-Bone'; justins="Justin's";
  peterpan='Peter Pan'; hiddenvalley='Hidden Valley'; maxwellhouse='Maxwell House'; cheerios='Honey Nut Cheerios';
  kens="Ken's"; dukes="Duke's"; hellmanns="Hellmann's"; smuckers="Smucker's"; armhammer='Arm & Hammer' }

# FF per item -> canon -> per
$ffMap=@{}
foreach($it in $ff.items){
  if($it.type -eq 'variety'){ continue }
  $m=@{}
  foreach($b in $it.brands){ $c=Canon ([string]$b.brand); if(-not $m.ContainsKey($c) -or [double]$b.per_unit -lt $m[$c].per){ $m[$c]=@{per=[double]$b.per_unit; store=[bool]$b.is_store_brand; label=[string]$b.brand} } }
  $ffMap[$it.id]=@{ label=$it.label; unit=$it.unit; brands=$m }
}
# WM per item
$wmMap=@{}
foreach($p in $wm.items.PSObject.Properties){
  $m=@{}
  foreach($b in $p.Value){ $c=Canon ([string]$b.b); if(-not $m.ContainsKey($c) -or [double]$b.per -lt $m[$c].per){ $m[$c]=@{per=[double]$b.per; store=[bool]$b.s; label=[string]$b.b} } }
  $wmMap[$p.Name]=$m
}

$items=@()
foreach($id in $ffMap.Keys){
  $ffI=$ffMap[$id]; $wmI=$wmMap[$id]
  $keys=@(@($ffI.brands.Keys) + @($wmI.Keys) | Select-Object -Unique)
  $brands=@()
  foreach($c in $keys){
    $ffp = if($ffI.brands.ContainsKey($c)){ [math]::Round($ffI.brands[$c].per,3) } else { $null }
    $wmp = if($wmI -and $wmI.ContainsKey($c)){ [math]::Round($wmI[$c].per,3) } else { $null }
    $isStore = ($ffI.brands.ContainsKey($c) -and $ffI.brands[$c].store) -or ($wmI -and $wmI.ContainsKey($c) -and $wmI[$c].store)
    $lab = if($labels.ContainsKey($c)){ $labels[$c] } elseif($ffI.brands.ContainsKey($c)){ $ffI.brands[$c].label } else { $wmI[$c].label }
    $vals=@($ffp,$wmp | Where-Object { $_ -ne $null })
    $min = if($vals.Count){ ($vals | Measure-Object -Minimum).Minimum } else { $null }
    $cheapest = if($ffp -ne $null -and $wmp -ne $null){ if($ffp -lt $wmp){'Family Fare'}elseif($wmp -lt $ffp){'Walmart'}else{'tie'} } elseif($ffp -ne $null){'Family Fare'} elseif($wmp -ne $null){'Walmart'} else {$null}
    $brands += ,([ordered]@{ key=$c; label=$lab; store=[bool]$isStore; ff=$ffp; wm=$wmp; min=$min; cheapest=$cheapest })
  }
  $brands=@($brands | Sort-Object { $_.min })
  $items += ,([ordered]@{ id=$id; label=$ffI.label; unit=$ffI.unit; brands=$brands })
}
# order items by biggest store-brand vs cheapest-name gap at FF (reuse swaps order roughly): keep as-is
$out=[ordered]@{ generated=(Get-Date -Format 'yyyy-MM-dd'); stores=@('Family Fare','Walmart'); items=$items }
($out | ConvertTo-Json -Depth 9 -Compress) | Set-Content (Join-Path $here '..\out\brands\cross-view.json') -Encoding UTF8
Write-Output ("cross-view: " + $items.Count + " items")
foreach($it in $items){ Write-Output ("`n"+$it.label); foreach($b in $it.brands){ Write-Output ("  {0,-20} FF {1,-7} WM {2,-7} -> {3}" -f ($b.label+($(if($b.store){' *'}else{''}))), ($(if($b.ff -ne $null){'$'+$b.ff}else{'-'})), ($(if($b.wm -ne $null){'$'+$b.wm}else{'-'})), $b.cheapest) } }