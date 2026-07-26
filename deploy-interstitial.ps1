# Add (idempotently) the join interstitial to Ghost site-wide codeinjection_foot via the Admin API.
$ErrorActionPreference='Stop'
$adminKey=(Get-Content 'C:\Codex\income\meal-prep\.ghostkey' -Raw).Trim()
$apiUrl='https://map-to-success.ghost.io'
$p=$adminKey -split ':'; $id=$p[0]; $secretHex=$p[1]
$sb=New-Object byte[] ($secretHex.Length/2); for($i=0;$i -lt $sb.Length;$i++){ $sb[$i]=[Convert]::ToByte($secretHex.Substring($i*2,2),16) }
$now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$h='{"alg":"HS256","typ":"JWT","kid":"'+$id+'"}'; $pl='{"iat":'+$now+',"exp":'+($now+300)+',"aud":"/admin/"}'
$b64={param($b)[Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_')}
$si=(& $b64 ([Text.Encoding]::UTF8.GetBytes($h)))+'.'+(& $b64 ([Text.Encoding]::UTF8.GetBytes($pl)))
$hm=New-Object System.Security.Cryptography.HMACSHA256 (,$sb); $jwt=$si+'.'+(& $b64 ($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes($si))))
$hdr=@{ Authorization="Ghost $jwt"; 'Accept-Version'='v5.0' }

$snippet=[IO.File]::ReadAllText('C:\Codex\income\join-interstitial.html')

# read current footer injection
$s=Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/settings/" -Headers $hdr -TimeoutSec 30
$foot=''; foreach($x in $s.settings){ if($x.key -eq 'codeinjection_foot'){ $foot=[string]$x.value } }
Write-Output ("current codeinjection_foot length: "+$foot.Length)

# idempotent: strip any prior interstitial block, then append the fresh one
$startM='<!-- tc-join-interstitial'; $endM='<!-- /tc-join-interstitial -->'
if($foot -and $foot.Contains($startM)){
  $si2=$foot.IndexOf($startM); $ei2=$foot.IndexOf($endM)
  if($ei2 -gt $si2){ $foot=$foot.Substring(0,$si2).TrimEnd() + $foot.Substring($ei2+$endM.Length) ; Write-Output 'removed prior interstitial block' }
}
$newFoot=($foot.TrimEnd() + "`n" + $snippet).Trim()

# PUT it back
$body=ConvertTo-Json @{ settings=@(@{ key='codeinjection_foot'; value=$newFoot }) } -Depth 6 -Compress
try{
  $r=Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/settings/" -Method Put -Headers $hdr -ContentType 'application/json;charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60
  $nf=''; foreach($x in $r.settings){ if($x.key -eq 'codeinjection_foot'){ $nf=[string]$x.value } }
  Write-Output ("PUT OK. new codeinjection_foot length: "+$nf.Length+"  contains interstitial: "+$nf.Contains('tc-join-interstitial'))
}catch{
  $resp=$_.Exception.Response
  if($resp){ $sr=New-Object IO.StreamReader($resp.GetResponseStream()); $txt=$sr.ReadToEnd(); Write-Output ("PUT FAILED HTTP "+[int]$resp.StatusCode+": "+$txt.Substring(0,[Math]::Min(500,$txt.Length))) }
  else{ Write-Output ("PUT FAILED: "+$_.Exception.Message) }
}