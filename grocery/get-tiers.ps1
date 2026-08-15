$ErrorActionPreference='Stop'
$here='C:\Codex\ThriftyCrew\grocery'
$adminKey = if (Test-Path (Join-Path $here '.ghostkey')) { (Get-Content (Join-Path $here '.ghostkey') -Raw).Trim() } else { (Get-Content 'C:\Codex\ThriftyCrew\meal-prep\.ghostkey' -Raw).Trim() }
$apiUrl='https://map-to-success.ghost.io'
$p=$adminKey -split ':'; $id=$p[0]; $secretHex=$p[1]
$sb=New-Object byte[] ($secretHex.Length/2); for($i=0;$i -lt $sb.Length;$i++){ $sb[$i]=[Convert]::ToByte($secretHex.Substring($i*2,2),16) }
$now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$h='{"alg":"HS256","typ":"JWT","kid":"'+$id+'"}'; $pl='{"iat":'+$now+',"exp":'+($now+300)+',"aud":"/admin/"}'
$b64={param($b)[Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_')}
$si=(& $b64 ([Text.Encoding]::UTF8.GetBytes($h)))+'.'+(& $b64 ([Text.Encoding]::UTF8.GetBytes($pl)))
$hm=New-Object System.Security.Cryptography.HMACSHA256 (,$sb); $jwt=$si+'.'+(& $b64 ($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes($si))))
$r=Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/tiers/?include=monthly_price,yearly_price&limit=all" -Headers @{Authorization="Ghost $jwt"; 'Accept-Version'='v5.0'} -TimeoutSec 30
foreach($t in $r.tiers){
  Write-Output ("tier: name='"+$t.name+"' id="+$t.id+" type="+$t.type+" active="+$t.active+" visibility="+$t.visibility+" monthly="+$t.monthly_price+" yearly="+$t.yearly_price+" currency="+$t.currency)
}