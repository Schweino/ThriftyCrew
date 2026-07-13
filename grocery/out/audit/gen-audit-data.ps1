# Generate ground-truth commodity-assignment data for the matching audit.
# Faithfully replicates compare-deals.ps1 Match-Category (include/exclude/GLOBAL/relax + FILE ORDER),
# runs it over EVERY raw product across all store inputs, and validates against the engine's own candidates.
$ErrorActionPreference='Stop'
$root='C:\Codex\income\grocery'; $out="$root\out\audit"
$tmp=ConvertFrom-Json ([IO.File]::ReadAllText("$root\commodities.json")); $commods=@($tmp)

# --- parse GLOBAL_EXCLUDE from compare-deals.ps1 (robust: whole-block regex, strip comments) ---
$cdtxt=[IO.File]::ReadAllText("$root\compare-deals.ps1")
$m=[regex]::Match($cdtxt, '\$GLOBAL_EXCLUDE = @\((?<b>[\s\S]*?)\r?\n\)')
$GLOBAL=@(); foreach($line in ($m.Groups['b'].Value -split "`n")){ if($line -match '^\s*#'){continue}; foreach($mm in [regex]::Matches($line,"'([^']*)'")){ $GLOBAL+=$mm.Groups[1].Value } }

function Match-Cat([string]$name){
  $n=$name.ToLower()
  $ghits=@(); foreach($g in $GLOBAL){ try{ if($n -match $g){$ghits+=$g} }catch{} }
  foreach($c in $commods){
    $hit=$false;$via=$null
    foreach($inc in $c.include){ try{ if($n -match $inc){$hit=$true;$via=$inc;break} }catch{} }
    if(-not $hit){continue}
    if($ghits.Count){ $relax=@($c.relax_global|Where-Object{$_}); $blocked=$false; foreach($g in $ghits){ if($relax -notcontains $g){$blocked=$true;break} }; if($blocked){continue} }
    $bad=$false; foreach($e in $c.exclude){ try{ if($n -match $e){$bad=$true;break} }catch{} }
    if($bad){continue}
    return [pscustomobject]@{id=$c.id;via=$via;ghits=($ghits -join '|')}
  }
  return $null
}

# --- gather every raw product (same inputs compare-deals reads) ---
$prods=New-Object System.Collections.Generic.List[object]
function AddP($store,$item,$size,$price,$src){ if(-not $store -or -not $item){return}; $prods.Add([pscustomobject]@{store=[string]$store;name=[string]$item;size=[string]$size;price=[string]$price;src=$src}) }
# regular (latest per store)
Get-ChildItem "$root\out\regular\*.json" | Group-Object { ($_.BaseName -replace '-regular-.*$','') } | ForEach-Object {
  $f=($_.Group | Sort-Object Name -Descending | Select-Object -First 1)
  $doc=ConvertFrom-Json ([IO.File]::ReadAllText($f.FullName))
  foreach($d in $doc.deals){ $s=if($doc.store){$doc.store}else{$d.store}; AddP $s $d.item $d.size $d.ad_price $f.Name }
}
# weekly ads (latest)
$adsF=Get-ChildItem "$root\out\ads-*.json" -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if($adsF){ foreach($d in (ConvertFrom-Json ([IO.File]::ReadAllText($adsF.FullName))).deals){ AddP $d.store $d.item $d.size_text $d.price_text $adsF.Name } }
# browser deal files (latest each)
foreach($g in @('bakers\bakers-deals-*.json','sams\sams-deals-*.json','fareway\fareway-deals-*.json')){
  $f=Get-ChildItem "$root\out\$g" -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if($f){ foreach($d in (ConvertFrom-Json ([IO.File]::ReadAllText($f.FullName))).deals){ AddP $d.store $d.item $d.size $d.ad_price $f.Name } }
}
# dedup identical (store|name|size|price)
$seen=@{}; $uniq=New-Object System.Collections.Generic.List[object]
foreach($p in $prods){ $k=$p.store+'|'+$p.name+'|'+$p.size+'|'+$p.price; if(-not $seen.ContainsKey($k)){ $seen[$k]=1; $uniq.Add($p) } }

# --- assign each product ---
$matched=New-Object System.Collections.Generic.List[object]
$unmatched=New-Object System.Collections.Generic.List[object]
foreach($p in $uniq){
  $c=Match-Cat $p.name
  if($c){ $matched.Add([pscustomobject]@{store=$p.store;name=$p.name;size=$p.size;price=$p.price;commodity=$c.id;via=$c.via;ghits=$c.ghits}) }
  else { $unmatched.Add([pscustomobject]@{store=$p.store;name=$p.name;size=$p.size;price=$p.price}) }
}

# --- VALIDATE against the engine's candidates-*.json (real matched product->commodity) ---
$candF=Get-ChildItem "$root\out\candidates-*.json" | Sort-Object Name -Descending | Select-Object -First 1
$cand=ConvertFrom-Json ([IO.File]::ReadAllText($candF.FullName))
$engMap=@{}   # store|name -> commodity id (from real engine)
foreach($cm in @($cand.commodities)){ foreach($cd in @($cm.candidates)){ $engMap[([string]$cd.store+'|'+[string]$cd.name)]=[string]$cm.id } }
$mineMap=@{}; foreach($mm in $matched){ $mineMap[($mm.store+'|'+$mm.name)]=$mm.commodity }
$disagree=New-Object System.Collections.Generic.List[object]
foreach($k in $engMap.Keys){ if($mineMap.ContainsKey($k) -and $mineMap[$k] -ne $engMap[$k]){ $disagree.Add([pscustomobject]@{key=$k;engine=$engMap[$k];mine=$mineMap[$k]}) } }
$engOnly=@($engMap.Keys | Where-Object { -not $mineMap.ContainsKey($_) })

Write-Output ("GLOBAL tokens: "+$GLOBAL.Count)
Write-Output ("raw products (dedup): "+$uniq.Count+"   matched: "+$matched.Count+"   unmatched: "+$unmatched.Count)
$jm = if($matched.Count){ ConvertTo-Json ($matched.ToArray()) -Depth 6 } else { '[]' }
Set-Content -Path "$out\assignments.json" -Value $jm -Encoding UTF8
$ju = if($unmatched.Count){ ConvertTo-Json ($unmatched.ToArray()) -Depth 6 } else { '[]' }
Set-Content -Path "$out\unmatched.json" -Value $ju -Encoding UTF8
Write-Output ("VALIDATION vs engine candidates: engine-matched keys="+$engMap.Count+"  DISAGREEMENTS="+$disagree.Count+"  engine-only(not in my matched)="+$engOnly.Count)
if($disagree.Count){ Write-Output "--- first 15 disagreements (my matcher vs engine) ---"; $disagree | Select-Object -First 15 | ForEach-Object { Write-Output ("  "+$_.key+"  engine="+$_.engine+"  mine="+$_.mine) } }
