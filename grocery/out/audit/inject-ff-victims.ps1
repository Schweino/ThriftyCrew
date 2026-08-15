# Immediate recovery: merge the 57 captured FF pull-drop victims (real Freshop prices, ~40 min ago) into a fresh
# Family Fare regular file so the board is correct NOW (the IP is temporarily 400-blocked from diagnostics, so a
# live re-pull must wait). compare-deals' matcher still gates correctness (over-broad captures get excluded).
$ErrorActionPreference='Stop'
$root='C:\Codex\ThriftyCrew\grocery'; $reg="$root\out\regular"
$prev=Get-ChildItem "$reg\family-fare-regular-*.json" | Sort-Object Name -Descending | Select-Object -First 1
$doc=ConvertFrom-Json ([IO.File]::ReadAllText($prev.FullName))
$deals=New-Object System.Collections.Generic.List[object]
$seen=@{}
foreach($d in $doc.deals){ $k=([string]$d.item+'|'+[string]$d.size); if(-not $seen.ContainsKey($k)){ $seen[$k]=$true; $deals.Add($d) } }
$before=$deals.Count
$tmpV=ConvertFrom-Json ([IO.File]::ReadAllText("$root\out\audit\ff-pulldrop-victims.json")); $victims=@($tmpV)
$added=0
foreach($v in $victims){
  $k=([string]$v.name+'|'+[string]$v.size)
  if($seen.ContainsKey($k)){ continue }
  $seen[$k]=$true
  $deals.Add([ordered]@{ store='Family Fare'; item=[string]$v.name; ad_price=('$'+$v.price); size=[string]$v.size; regular=$v.price; source_ad='everyday shelf price (recovered 2026-07-13)' })
  $added++
}
$todayS=(Get-Date).ToString('yyyy-MM-dd')
$out=[ordered]@{ store='Family Fare'; week_of=$todayS; price_type='everyday'; source=$doc.source; deal_count=$deals.Count; empty_terms=@(); deals=$deals }
$file="$reg\family-fare-regular-$todayS.json"
($out | ConvertTo-Json -Depth 6) | Set-Content $file -Encoding UTF8
Write-Output ("merged: "+$before+" existing + "+$added+" recovered victims = "+$deals.Count+" -> "+$file)
Write-Output ("ground pork present now: "+([bool](@($deals)|Where-Object{[string]$_.item -match '(?i)ground pork'})))