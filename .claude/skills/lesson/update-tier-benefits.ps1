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
$t = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/tiers/?include=benefits&limit=all" -Headers $H).tiers | Where-Object { $_.name -eq "All Access" }
if (-not $t) { throw "All Access tier not found" }
Write-Host ("Tier id={0}  current benefits: {1}" -f $t.id, ($t.benefits -join ' | ')) -ForegroundColor DarkGray

$newBenefit = "Money tools: budget tracker + calculators"
$benefits = @($t.benefits) + $newBenefit
# de-dupe in case of re-run
$benefits = $benefits | Select-Object -Unique

$tierObj = [ordered]@{
  name = $t.name
  description = $t.description
  welcome_page_url = $t.welcome_page_url
  visibility = $t.visibility
  benefits = $benefits
  updated_at = $t.updated_at
}
$payload = @{ tiers = @($tierObj) }
$bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $payload -Depth 8))
$jwt2 = New-GhostJWT $adminKey
try {
  $r = Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/tiers/$($t.id)/" -Method Put -Headers @{ Authorization="Ghost $jwt2"; 'Accept-Version'='v5.0' } -ContentType 'application/json' -Body $bytes -TimeoutSec 30
  Write-Host ("UPDATED tier. benefits now: {0}" -f ($r.tiers[0].benefits -join ' | ')) -ForegroundColor Green
} catch {
  Write-Host "PUT failed: $($_.Exception.Message)" -ForegroundColor Red
  if ($_.Exception.Response) { $rd=New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream()); Write-Host $rd.ReadToEnd() }
}
