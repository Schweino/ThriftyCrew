# Apply the structured audit patch to commodities.json. Validates every regex; reports each change.
$ErrorActionPreference='Stop'
$root='C:\Codex\income\grocery'; $out="$root\out\audit"
Copy-Item "$root\commodities.json" "$out\commodities.before-patch.json" -Force
$tmp=ConvertFrom-Json ([IO.File]::ReadAllText("$root\commodities.json")); $commods=@($tmp)
$byId=@{}; foreach($c in $commods){ $byId[[string]$c.id]=$c }
$patch=ConvertFrom-Json ([IO.File]::ReadAllText("$out\patch.json"))
$log=New-Object System.Collections.Generic.List[string]
$err=New-Object System.Collections.Generic.List[string]
function ChkRx($rx){ try{ [void][regex]::new($rx); $true }catch{ $false } }
function EnsureArr($c,$prop){ if(-not $c.PSObject.Properties[$prop]){ $c | Add-Member -NotePropertyName $prop -NotePropertyValue @() }; if($null -eq $c.$prop){ $c.$prop=@() } }
foreach($op in @($patch.ops)){
  $c=$byId[[string]$op.commodity]
  if(-not $c){ $err.Add("MISSING commodity: "+$op.commodity); continue }
  switch($op.op){
    'add-exclude' { EnsureArr $c 'exclude'; $a=@($c.exclude); foreach($t in @($op.tokens)){ if(-not (ChkRx $t)){$err.Add("bad regex ("+$op.commodity+" exclude): "+$t);continue}; if($a -notcontains $t){$a+=$t; $log.Add("  +exc  "+$op.commodity.PadRight(18)+" "+$t)} }; $c.exclude=$a }
    'add-include' { EnsureArr $c 'include'; $a=@($c.include); foreach($t in @($op.patterns)){ if(-not (ChkRx $t)){$err.Add("bad regex ("+$op.commodity+" include): "+$t);continue}; if($a -notcontains $t){$a+=$t; $log.Add("  +inc  "+$op.commodity.PadRight(18)+" "+$t)} }; $c.include=$a }
    'add-relax'   { EnsureArr $c 'relax_global'; $a=@($c.relax_global|Where-Object{$_}); foreach($t in @($op.tokens)){ if(-not (ChkRx $t)){$err.Add("bad regex ("+$op.commodity+" relax): "+$t);continue}; if($a -notcontains $t){$a+=$t; $log.Add("  +relax "+$op.commodity.PadRight(18)+" "+$t)} }; $c.relax_global=$a }
    'replace-in'  { $arr=[string]$op.array; EnsureArr $c $arr; $a=@($c.$arr); $idx=[array]::IndexOf($a,[string]$op.old)
                    if($idx -lt 0){ $err.Add("replace-in OLD not found ("+$op.commodity+" "+$arr+"): '"+$op.old+"'") }
                    elseif(-not (ChkRx $op.new)){ $err.Add("bad regex ("+$op.commodity+" "+$arr+" new): "+$op.new) }
                    else { $a[$idx]=[string]$op.new; $c.$arr=$a; $log.Add("  ~"+$arr.Substring(0,3)+"  "+$op.commodity.PadRight(18)+" '"+$op.old+"' -> '"+$op.new+"'") } }
    'set-unit'    { $log.Add("  unit  "+$op.commodity.PadRight(18)+" "+$c.unit+" -> "+$op.unit); $c.unit=[string]$op.unit }
    default       { $err.Add("unknown op: "+$op.op+" ("+$op.commodity+")") }
  }
}
if($err.Count){ Write-Output ("ERRORS ("+$err.Count+"):"); $err | ForEach-Object { Write-Output ("  !! "+$_) }; Write-Output ""; Write-Output "ABORTING - commodities.json NOT written."; exit 1 }
[IO.File]::WriteAllText("$root\commodities.json",(ConvertTo-Json $commods -Depth 12),(New-Object Text.UTF8Encoding($false)))
Write-Output ("applied "+$log.Count+" field changes across the patch, 0 errors")
$log | ForEach-Object { Write-Output $_ }
Write-Output ""
Write-Output "commodities.json written; backup at out\audit\commodities.before-patch.json"