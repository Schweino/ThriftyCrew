$ErrorActionPreference='Stop'
$j='C:\Users\Owner\.claude\projects\C--Codex\f3644374-5e4d-4c5e-a7e6-7ac3b89873f9\subagents\workflows\wf_118ee387-f57\journal.jsonl'
$out='C:\Codex\ThriftyCrew\grocery\out\audit'
$res=@(Get-Content $j | ForEach-Object { try{ $o=ConvertFrom-Json $_; if($o.type -eq 'result'){$o} }catch{} })
$verify=New-Object System.Collections.Generic.List[object]
$auditCount=0
foreach($r in $res){
  $rv=$r.result
  if($rv.PSObject.Properties['results']){ foreach($x in @($rv.results)){ $verify.Add($x) } }
  elseif($rv.PSObject.Properties['findings']){ $auditCount += @($rv.findings).Count }
}
Write-Output ("verify verdicts total: "+$verify.Count+"   (raw audit findings across agents: "+$auditCount+")")
$conf=@($verify | Where-Object { $_.verdict -eq 'CONFIRMED' })
$rej =@($verify | Where-Object { $_.verdict -eq 'REJECTED' })
$unc =@($verify | Where-Object { $_.verdict -eq 'UNCERTAIN' })
Write-Output ("CONFIRMED="+$conf.Count+"  REJECTED="+$rej.Count+"  UNCERTAIN="+$unc.Count)
Write-Output ("  confirmed & fix_safe=true: "+@($conf|Where-Object{$_.fix_safe}).Count+"   fix_safe=false: "+@($conf|Where-Object{-not $_.fix_safe}).Count)
Write-Output ""
Write-Output "=== CONFIRMED by severity x issue_type ==="
foreach($sev in 'high','med','low'){
  $g=@($conf|Where-Object{$_.severity -eq $sev})
  Write-Output ("  severity="+$sev+"  ("+$g.Count+")")
  $g | Group-Object issue_type | Sort-Object Count -Descending | ForEach-Object { Write-Output ("      "+([string]$_.Name).PadRight(18)+" "+$_.Count) }
}
# also findings with blank/other severity
$other=@($conf|Where-Object{$_.severity -notin 'high','med','low'})
if($other.Count){ Write-Output ("  severity=OTHER/blank ("+$other.Count+")") }
$conf | ConvertTo-Json -Depth 5 | Set-Content "$out\confirmed-clean.json" -Encoding UTF8
Write-Output ""
Write-Output ("wrote confirmed-clean.json ("+$conf.Count+")")