$ErrorActionPreference = "Stop"
Write-Host "STEP 1: dot-sourcing config" -ForegroundColor Cyan
. "$PSScriptRoot\ghost-config.ps1"
Write-Host "STEP 2: config loaded, apiUrl=$apiUrl" -ForegroundColor Cyan

function New-GhostJWT { param($key)
  $p=$key -split ':'; $id=$p[0]; $secretHex=$p[1]
  $sb=New-Object byte[] ($secretHex.Length/2)
  for($i=0;$i -lt $sb.Length;$i++){ $sb[$i]=[Convert]::ToByte($secretHex.Substring($i*2,2),16) }
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $h='{"alg":"HS256","typ":"JWT","kid":"'+$id+'"}'; $pl='{"iat":'+$now+',"exp":'+($now+300)+',"aud":"/admin/"}'
  $b64={param($b)[Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_')}
  $si=(& $b64 ([Text.Encoding]::UTF8.GetBytes($h)))+'.'+(& $b64 ([Text.Encoding]::UTF8.GetBytes($pl)))
  $hm=New-Object System.Security.Cryptography.HMACSHA256 (,$sb); return $si+'.'+(& $b64 ($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes($si))))
}
Write-Host "STEP 3: building JWT" -ForegroundColor Cyan
$jwt = New-GhostJWT $adminKey
Write-Host "STEP 4: JWT built, length=$($jwt.Length)" -ForegroundColor Cyan

Write-Host "STEP 5: GET existing buffer post (TimeoutSec 15)" -ForegroundColor Cyan
try {
  $r = Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/zz-inject-buffer/?fields=id,updated_at" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -TimeoutSec 15
  Write-Host "STEP 6: GET succeeded, found post id=$($r.posts[0].id)" -ForegroundColor Green
} catch {
  Write-Host "STEP 6: GET failed/404 (expected if none exists): $($_.Exception.Message)" -ForegroundColor Yellow
}
Write-Host "DONE" -ForegroundColor Green
