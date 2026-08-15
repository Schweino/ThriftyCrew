$ErrorActionPreference='Stop'
$adminKey=(Get-Content 'C:\Codex\ThriftyCrew\meal-prep\.ghostkey' -Raw).Trim()
$apiUrl='https://map-to-success.ghost.io'
$p=$adminKey -split ':'; $id=$p[0]; $secretHex=$p[1]
$sb=New-Object byte[] ($secretHex.Length/2); for($i=0;$i -lt $sb.Length;$i++){ $sb[$i]=[Convert]::ToByte($secretHex.Substring($i*2,2),16) }
$now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$h='{"alg":"HS256","typ":"JWT","kid":"'+$id+'"}'; $pl='{"iat":'+$now+',"exp":'+($now+300)+',"aud":"/admin/"}'
$b64={param($b)[Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_')}
$si=(& $b64 ([Text.Encoding]::UTF8.GetBytes($h)))+'.'+(& $b64 ([Text.Encoding]::UTF8.GetBytes($pl)))
$hm=New-Object System.Security.Cryptography.HMACSHA256 (,$sb); $jwt=$si+'.'+(& $b64 ($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes($si))))
$hdr=@{ Authorization="Ghost $jwt"; 'Accept-Version'='v5.0' }
$r=Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/start-here/?formats=html,lexical" -Headers $hdr -TimeoutSec 30
$post=$r.posts[0]
Write-Output ("id: "+$post.id)
Write-Output ("title: "+$post.title)
Write-Output ("type: "+$post.type+"  status: "+$post.status+"  visibility: "+$post.visibility)
Write-Output ("updated_at: "+$post.updated_at)
Write-Output ("html length: "+([string]$post.html).Length)
Write-Output ("feature_image: "+$post.feature_image)
Write-Output ("excerpt: "+$post.custom_excerpt)
# save current html as a backup
[IO.File]::WriteAllText('C:\Codex\ThriftyCrew\archive\site-backups\start-here.before.html', [string]$post.html, (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText('C:\Codex\ThriftyCrew\_starthere.id.txt', ($post.id+'|'+$post.updated_at), (New-Object Text.UTF8Encoding($false)))
Write-Output "backed up current html -> site-backups\start-here.before.html"