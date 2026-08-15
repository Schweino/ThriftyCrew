$ErrorActionPreference = "Stop"
. "$PSScriptRoot\ghost-config.ps1"
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
$jwt = New-GhostJWT $adminKey
$H = @{ Authorization="Ghost $jwt"; 'Accept-Version'='v5.0' }

Write-Host "===== SETTINGS matching welcome-email text =====" -ForegroundColor Cyan
$s = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/settings/" -Headers $H).settings
foreach($kv in $s){ $v=[string]$kv.value; if($v -match 'Email us|glad you|welcome|read every|Start here|whole map'){ Write-Host ("  [{0}]" -f $kv.key) -ForegroundColor Yellow; if($v.Length -gt 300){$v=$v.Substring(0,300)+'...'}; Write-Host "    $v" } }

Write-Host "`n===== NEWSLETTERS =====" -ForegroundColor Cyan
try {
  $nl = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/newsletters/?limit=all" -Headers $H).newsletters
  foreach($n in $nl){ Write-Host ("  [{0}] status={1} sender_email={2} sender_reply_to={3}" -f $n.name,$n.status,$n.sender_email,$n.sender_reply_to)
    Write-Host ("     header_image={0} show_header_title={1} footer_content: {2}" -f $n.header_image,$n.show_header_title,($n.footer_content)) }
} catch { Write-Host "  newsletters fetch failed: $($_.Exception.Message)" }

Write-Host "`n===== ALL SETTING KEYS =====" -ForegroundColor Cyan
Write-Host (($s | ForEach-Object { $_.key }) -join ', ')
