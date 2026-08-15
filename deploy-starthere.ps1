$ErrorActionPreference='Stop'
$adminKey=(Get-Content 'C:\Codex\ThriftyCrew\meal-prep\.ghostkey' -Raw).Trim()
$apiUrl='https://map-to-success.ghost.io'
$p=$adminKey -split ':'; $id=$p[0]; $secretHex=$p[1]
$sb=New-Object byte[] ($secretHex.Length/2); for($i=0;$i -lt $sb.Length;$i++){ $sb[$i]=[Convert]::ToByte($secretHex.Substring($i*2,2),16) }
function New-Jwt {
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $h='{"alg":"HS256","typ":"JWT","kid":"'+$id+'"}'; $pl='{"iat":'+$now+',"exp":'+($now+300)+',"aud":"/admin/"}'
  $b64={param($b)[Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_')}
  $si=(& $b64 ([Text.Encoding]::UTF8.GetBytes($h)))+'.'+(& $b64 ([Text.Encoding]::UTF8.GetBytes($pl)))
  $hm=New-Object System.Security.Cryptography.HMACSHA256 (,$sb)
  $si+'.'+(& $b64 ($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes($si))))
}
$hdr=@{ Authorization=("Ghost "+(New-Jwt)); 'Accept-Version'='v5.0' }
# fresh GET for current updated_at
$cur=(Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/start-here/" -Headers $hdr -TimeoutSec 30).posts[0]
$postId=$cur.id; $updatedAt=$cur.updated_at
Write-Output ("target post: "+$postId+"  updated_at: "+$updatedAt)
$html=[IO.File]::ReadAllText('C:\Codex\ThriftyCrew\start-here.new.html')
$body=@{ posts=@(@{ updated_at=$updatedAt; html=$html }) } | ConvertTo-Json -Depth 6 -Compress
$hdr2=@{ Authorization=("Ghost "+(New-Jwt)); 'Accept-Version'='v5.0' }
$res=Invoke-RestMethod -Method Put -Uri "$apiUrl/ghost/api/admin/posts/$postId/?source=html" -Headers $hdr2 -ContentType 'application/json' -Body $body -TimeoutSec 60
$out=$res.posts[0]
Write-Output ("PUT ok. status: "+$out.status+"  new updated_at: "+$out.updated_at)
Write-Output ("new html length: "+([string]$out.html).Length)
Write-Output ("url: "+$out.url)