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

Write-Host "===== PAGES =====" -ForegroundColor Cyan
foreach($slug in @("welcome","welcome-all-access","membership")){
  try {
    $p = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/pages/slug/$slug/?formats=html" -Headers $H).pages[0]
    Write-Host ("--- /{0}/  (id {1})  title: {2}" -f $slug, $p.id, $p.title) -ForegroundColor Yellow
    $txt = ($p.html -replace '<[^>]+>',' ') -replace '\s+',' '
    Write-Host ("    "+$txt.Substring(0,[Math]::Min(700,$txt.Length)))
  } catch { Write-Host "  /$slug/ not found" -ForegroundColor DarkGray }
}

Write-Host "`n===== TIERS =====" -ForegroundColor Cyan
$tiers = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/tiers/?include=benefits&limit=all" -Headers $H).tiers
foreach($t in $tiers){ Write-Host ("  [{0}] visibility={1} desc='{2}' benefits: {3}" -f $t.name,$t.visibility,$t.description,(($t.benefits) -join ' | ')) }

Write-Host "`n===== SETTINGS (welcome/portal/signup/members) =====" -ForegroundColor Cyan
$s = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/settings/" -Headers $H).settings
foreach($kv in $s){ if($kv.key -match 'welcome|portal|signup|members_|firstpromoter|comments'){ $v=[string]$kv.value; if($v.Length -gt 160){$v=$v.Substring(0,160)+'...'}; Write-Host ("  {0} = {1}" -f $kv.key,$v) } }
