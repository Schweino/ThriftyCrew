<#
  build-item-request-page.ps1  -  Creates/updates the "/suggest-an-item/" page: the branded
  item-request form (grocery/item-request-form.html) that POSTs to the smp-feed Worker /submit
  endpoint, which emails contact@simplemoneyplaybook.com. Idempotent (PUT if the page exists).
#>
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\ghost-config.ps1"   # -> $adminKey, $apiUrl
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

$html = Get-Content 'C:\Codex\ThriftyCrew\grocery\item-request-form.html' -Raw

$title    = 'Suggest an Item'
$slug     = 'suggest-an-item'
$metaTitle = 'Suggest an Item | Thrifty Crew'
$metaDesc  = "Found a grocery deal we should be tracking? Send us the store, item name, and product link and we'll look at adding it to the price board."

$jwt = New-GhostJWT $adminKey
$existing = $null
try { $existing = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/pages/slug/$slug/?fields=id,updated_at" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}).pages[0] } catch {}

$lexObj = @{ root = [ordered]@{ children=@([ordered]@{ type='html'; version=1; html=[string]$html }); direction=$null; format=''; indent=0; type='root'; version=1 } }
$lex = ConvertTo-Json $lexObj -Depth 12 -Compress
$pageObj = [ordered]@{ title=$title; slug=$slug; lexical=$lex; status='published'; meta_title=$metaTitle; meta_description=$metaDesc; og_title=$metaTitle; og_description=$metaDesc; twitter_title=$metaTitle; twitter_description=$metaDesc }
if ($existing) { $pageObj.updated_at=$existing.updated_at; $method='Put'; $uri="$apiUrl/ghost/api/admin/pages/$($existing.id)/" }
else { $method='Post'; $uri="$apiUrl/ghost/api/admin/pages/" }

$payload = @{ pages=@($pageObj) }
$bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $payload -Depth 16))
$jwt2 = New-GhostJWT $adminKey
$res = Invoke-RestMethod -Uri $uri -Method $method -Headers @{Authorization="Ghost $jwt2";'Accept-Version'='v5.0'} -ContentType 'application/json' -Body $bytes
$verb = if ($existing) { 'Updated' } else { 'Created' }
Write-Host ("{0}: {1}/{2}/  (url: https://www.simplemoneyplaybook.com/{2}/)" -f $verb, $apiUrl, $slug) -ForegroundColor Green
