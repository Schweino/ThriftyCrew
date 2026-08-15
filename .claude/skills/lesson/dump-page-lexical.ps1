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
$sp = "C:\Users\Owner\AppData\Local\Temp\claude\C--Codex\f3644374-5e4d-4c5e-a7e6-7ac3b89873f9\scratchpad"
foreach($slug in @("membership","welcome","welcome-all-access")){
  $p = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/pages/slug/$slug/?formats=lexical" -Headers $H).pages[0]
  $lex = $p.lexical
  # detect structure: how many top-level children, and are they html cards?
  $obj = $lex | ConvertFrom-Json
  $kids = $obj.root.children
  Write-Host ("/{0}/  id={1}  topLevelChildren={2}  types={3}" -f $slug,$p.id,$kids.Count,(($kids | ForEach-Object { $_.type }) -join ',')) -ForegroundColor Cyan
  [IO.File]::WriteAllText("$sp\page-$slug.lexical.json", $lex, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "  saved page-$slug.lexical.json ($($lex.Length) chars)"
}
