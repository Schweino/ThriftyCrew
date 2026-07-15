param([string[]]$Ids)
$ErrorActionPreference = 'Stop'; $root = $PSScriptRoot
$UA = @{ 'User-Agent'='Mozilla/5.0'; 'Accept'='application/json' }
$ak='family_fare'; $sid='6401'
function Tok { foreach($u in @("https://api.freshop.ncrcloud.com/2/sessions?app_key=$ak","https://api.freshop.ncrcloud.com/1/sessions?app_key=$ak")){ try{ $t=Invoke-RestMethod -Uri $u -Method Post -Headers $UA -TimeoutSec 20; if($t.token){return [string]$t.token} }catch{} }; return '' }
$tok = Tok
$terms = (Get-Content (Join-Path $root 'commodity-search.json') -Raw | ConvertFrom-Json).terms
$comm = @{}; foreach($c in (Get-Content (Join-Path $root 'commodities.json') -Raw|ConvertFrom-Json)){ $comm[[string]$c.id]=$c }
foreach($id in $Ids){
  $term = [string]$terms.$id
  $cm = $comm[$id]
  $r = @()
  try { $r = @((Invoke-RestMethod -Uri ("https://api.freshop.ncrcloud.com/1/products?app_key=$ak&store_id=$sid&token=$tok&limit=15&fields=name,size,base_price&q=" + [uri]::EscapeDataString($term)) -Headers $UA -TimeoutSec 25).items) } catch { Write-Output ("$id : QUERY ERROR"); continue }
  Write-Output ("### $id   term='$term'   freshop returned $($r.Count)")
  $matched = 0
  foreach($p in ($r | Select-Object -First 8)){
    $nm=[string]$p.name
    $inc=$false; foreach($pat in @($cm.include)){ if($pat -and $nm -imatch $pat){$inc=$true;break} }
    $bad=$false; foreach($pat in @($cm.exclude)){ if($pat -and $nm -imatch $pat){$bad=$true;break} }
    $verdict = if($inc -and -not $bad){'MATCH'}elseif($inc -and $bad){'excluded'}else{'no-include'}
    if($verdict -eq 'MATCH'){$matched++}
    Write-Output ("   [{0,-10}] `${1,-6} {2}" -f $verdict, $p.base_price, $nm.Substring(0,[Math]::Min(52,$nm.Length)))
  }
  Write-Output ("   => $matched of first 8 would MATCH")
  Start-Sleep -Milliseconds 400
}
