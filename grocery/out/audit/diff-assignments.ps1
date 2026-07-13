# Diff pre-patch vs post-patch commodity assignments. The regression gate for the audit patch.
$ErrorActionPreference='Stop'
$out='C:\Codex\income\grocery\out\audit'
function LoadMap($aFile,$uFile){
  $map=@{}
  $ta=ConvertFrom-Json ([IO.File]::ReadAllText($aFile)); foreach($p in @($ta)){ $map[($p.store+'|'+$p.name)]=[string]$p.commodity }
  $tu=ConvertFrom-Json ([IO.File]::ReadAllText($uFile)); foreach($p in @($tu)){ $map[($p.store+'|'+$p.name)]='<unmatched>' }
  return $map
}
$before=LoadMap "$out\assignments.before.json" "$out\unmatched.before.json"
$after =LoadMap "$out\assignments.json"        "$out\unmatched.json"
$moved=New-Object System.Collections.Generic.List[object]
$recovered=New-Object System.Collections.Generic.List[object]
$dropped=New-Object System.Collections.Generic.List[object]
foreach($k in $before.Keys){
  if(-not $after.ContainsKey($k)){ continue }
  $b=$before[$k]; $a=$after[$k]
  if($b -eq $a){ continue }
  $nm=$k.Substring($k.IndexOf('|')+1); $st=$k.Substring(0,$k.IndexOf('|'))
  $o=[pscustomobject]@{store=$st;name=$nm;from=$b;to=$a}
  if($b -eq '<unmatched>'){ $recovered.Add($o) }
  elseif($a -eq '<unmatched>'){ $dropped.Add($o) }
  else{ $moved.Add($o) }
}
Write-Output ("TOTAL products compared: "+$before.Count)
Write-Output ("  MOVED (commodity A->B): "+$moved.Count)
Write-Output ("  RECOVERED (unmatched->matched): "+$recovered.Count)
Write-Output ("  DROPPED (matched->unmatched) [REGRESSION RISK]: "+$dropped.Count)
Write-Output ""
Write-Output "=== DROPPED (each must be an intended removal of a WRONG match, not a lost good one) ==="
$dropped | Sort-Object from | ForEach-Object { Write-Output ("  "+$_.from.PadRight(18)+" X  "+$_.store+" | "+$_.name) }
Write-Output ""
Write-Output "=== MOVED (each should be product going to its CORRECT commodity) ==="
$moved | Sort-Object from | ForEach-Object { Write-Output ("  "+$_.from.PadRight(16)+" -> "+$_.to.PadRight(16)+"  "+$_.store+" | "+$_.name) }
Write-Output ""
Write-Output ("=== RECOVERED ("+$recovered.Count+") newly matched staples ===")
$recovered | Sort-Object to | ForEach-Object { Write-Output ("  ->"+$_.to.PadRight(18)+" "+$_.store+" | "+$_.name) }