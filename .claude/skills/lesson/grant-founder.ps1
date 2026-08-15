<#
  grant-founder.ps1  -  Grants LIFETIME "All Access" (complimentary membership) to one email.
  Ghost has no native one-time/lifetime tier, so the Founder flow is:
    1) buyer pays once via a Stripe Payment Link (set up in the Stripe dashboard), then
    2) run this to give them permanent All Access with NO recurring charge (a "comp" membership).
  Usage:
    powershell -ExecutionPolicy Bypass -File grant-founder.ps1 -Email "jamie@example.com" -Name "Jamie Larson" -Amount "49"
  Upserts by email (safe to re-run). Does NOT send an email; tell the founder to "Sign in" on the
  site with this email to get their magic-link login.
#>
param(
  [Parameter(Mandatory=$true)][string]$Email,
  [string]$Name = '',
  [string]$Amount = ''
)
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
# All Access (the paid tier) id
$jwt=New-GhostJWT $adminKey
$tier=((Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/tiers/?limit=all" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}).tiers | Where-Object { $_.type -eq 'paid' } | Select-Object -First 1)
if (-not $tier) { throw "No paid tier found." }
$note = "Founding Member - one-time lifetime purchase" + $(if($Amount){" (`$$Amount)"}) + " - granted " + (Get-Date -Format 'yyyy-MM-dd')
$memberObj = [ordered]@{
  tiers  = @([ordered]@{ id=$tier.id; expiry_at=$null })   # expiry_at null = lifetime comp
  labels = @([ordered]@{ name='Founding Member' })
  note   = $note
}
if ($Name) { $memberObj.name = $Name }
# upsert by email
$jwt=New-GhostJWT $adminKey
$existing=$null
try { $flt=[uri]::EscapeDataString("email:'$Email'"); $existing=(Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/members/?filter=$flt&limit=1&fields=id,email" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}).members[0] } catch {}
if ($existing) { $method='Put'; $uri="$apiUrl/ghost/api/admin/members/$($existing.id)/" }
else { $memberObj.email=$Email; $method='Post'; $uri="$apiUrl/ghost/api/admin/members/" }
$body=[Text.Encoding]::UTF8.GetBytes((@{ members=@($memberObj) } | ConvertTo-Json -Depth 8))
$jwt=New-GhostJWT $adminKey
try {
  $r=(Invoke-RestMethod -Uri $uri -Method $method -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -ContentType 'application/json' -Body $body).members[0]
  Write-Host ("GRANTED lifetime All Access (comp) to {0}" -f $r.email) -ForegroundColor Green
  Write-Host ("  tiers={0}  status={1}  label=Founding Member" -f (($r.tiers | ForEach-Object {$_.name}) -join ','), $r.status)
} catch { Write-Host ("FAILED: {0}" -f $_.ErrorDetails.Message) -ForegroundColor Red }
