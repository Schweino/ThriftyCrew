# Build the human/agent-readable audit artifacts from assignments.json + commodities.json.
$ErrorActionPreference='Stop'
$root='C:\Codex\ThriftyCrew\grocery'; $out="$root\out\audit"
$tmp=ConvertFrom-Json ([IO.File]::ReadAllText("$root\commodities.json")); $commods=@($tmp)
$cats=(ConvertFrom-Json ([IO.File]::ReadAllText("$root\categories.json"))).categories
$ta=ConvertFrom-Json ([IO.File]::ReadAllText("$out\assignments.json")); $assign=@($ta)
$tu=ConvertFrom-Json ([IO.File]::ReadAllText("$out\unmatched.json")); $unm=@($tu)
# GLOBAL parse (same as gen-audit-data)
$cdtxt=[IO.File]::ReadAllText("$root\compare-deals.ps1")
$m=[regex]::Match($cdtxt,'\$GLOBAL_EXCLUDE = @\((?<b>[\s\S]*?)\r?\n\)')
$GLOBAL=@(); foreach($line in ($m.Groups['b'].Value -split "`n")){ if($line -match '^\s*#'){continue}; foreach($mm in [regex]::Matches($line,"'([^']*)'")){ $GLOBAL+=$mm.Groups[1].Value } }

# 1) assignments grouped by commodity (compact)
$byCom=$assign | Group-Object commodity
$lines=New-Object System.Collections.Generic.List[string]
foreach($g in ($byCom | Sort-Object Name)){
  $lines.Add("### "+$g.Name+"  ("+$g.Count+" products)")
  foreach($p in ($g.Group | Sort-Object store)){ $lines.Add(("  {0,-12} | {1} | {2} | {3}" -f $p.store,$p.name,$p.size,$p.price)) }
}
Set-Content "$out\by-commodity.txt" -Value ($lines -join "`n") -Encoding UTF8

# 2) unmatched compact
$ul=New-Object System.Collections.Generic.List[string]
foreach($p in ($unm | Sort-Object store,name)){ $ul.Add(("{0,-12} | {1} | {2} | {3}" -f $p.store,$p.name,$p.size,$p.price)) }
Set-Content "$out\unmatched.txt" -Value ($ul -join "`n") -Encoding UTF8

# 3) CONTESTED: products where >1 commodity is ELIGIBLE (include match + not excluded + not global-blocked-unless-relaxed).
#    Winner = first in file order. These are the order-dependence risk zone.
function Eligible([string]$name){
  $n=$name.ToLower()
  $ghits=@(); foreach($g in $GLOBAL){ try{ if($n -match $g){$ghits+=$g} }catch{} }
  $elig=@()
  foreach($c in $commods){
    $hit=$false; foreach($inc in $c.include){ try{ if($n -match $inc){$hit=$true;break} }catch{} }
    if(-not $hit){continue}
    if($ghits.Count){ $relax=@($c.relax_global|Where-Object{$_}); $blk=$false; foreach($g in $ghits){ if($relax -notcontains $g){$blk=$true;break} }; if($blk){continue} }
    $bad=$false; foreach($e in $c.exclude){ try{ if($n -match $e){$bad=$true;break} }catch{} }
    if($bad){continue}
    $elig+=$c.id
  }
  return $elig
}
$contest=New-Object System.Collections.Generic.List[object]
$seenNames=@{}
foreach($p in $assign){
  if($seenNames.ContainsKey($p.name)){continue}; $seenNames[$p.name]=1
  $e=Eligible $p.name
  if($e.Count -gt 1){ $contest.Add([pscustomobject]@{name=$p.name;winner=$e[0];eligible=($e -join ' > ')}) }
}
$jc = if($contest.Count){ ConvertTo-Json ($contest.ToArray()) -Depth 4 } else { '[]' }
Set-Content "$out\contested.json" -Value $jc -Encoding UTF8
$cl=New-Object System.Collections.Generic.List[string]
foreach($c in ($contest | Sort-Object winner)){ $cl.Add(("WINNER {0,-16} <= [{1}]  '{2}'" -f $c.winner,$c.eligible,$c.name)) }
Set-Content "$out\contested.txt" -Value ($cl -join "`n") -Encoding UTF8

# 4) category -> commodities map with rules (for slicing the fan-out)
$catMap=New-Object System.Collections.Generic.List[string]
$byId=@{}; foreach($c in $commods){ $byId[[string]$c.id]=$c }
$assignedCat=@{}
foreach($cat in $cats){ foreach($cid in $cat.commodities){ $assignedCat[[string]$cid]=$cat.key } }
foreach($cat in $cats){
  $catMap.Add("## CATEGORY: "+$cat.key+"  ("+@($cat.commodities).Count+" commodities)")
  foreach($cid in $cat.commodities){ $c=$byId[[string]$cid]; if($c){ $catMap.Add(("  {0,-20} unit={1} inc=[{2}] exc=[{3}] relax=[{4}]" -f $c.id,$c.unit,($c.include -join ', '),($c.exclude -join ', '),($c.relax_global -join ', '))) } }
}
$noCat=@($commods | Where-Object { -not $assignedCat.ContainsKey([string]$_.id) })
if($noCat.Count){ $catMap.Add("## (no category): "+(@($noCat|ForEach-Object{$_.id}) -join ', ')) }
Set-Content "$out\category-rules.txt" -Value ($catMap -join "`n") -Encoding UTF8

Write-Output ("assignments: "+$assign.Count+"  unmatched: "+$unm.Count+"  contested(distinct names): "+$contest.Count)
Write-Output ("categories: "+@($cats).Count+"  commodities: "+$commods.Count+"  no-category: "+$noCat.Count)
Write-Output ("wrote: by-commodity.txt, unmatched.txt, contested.json/.txt, category-rules.txt")
Write-Output "--- contested winners histogram (top 20 commodities that win contested products) ---"
$contest | Group-Object winner | Sort-Object Count -Descending | Select-Object -First 20 | ForEach-Object { Write-Output ("  {0,-18} {1}" -f $_.Name,$_.Count) }
