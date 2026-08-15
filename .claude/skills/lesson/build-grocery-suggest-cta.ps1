<#
  build-grocery-suggest-cta.ps1 - Appends (idempotently) a "Suggest an item" CTA card to the
  /omaha-grocery-prices/ page, linking to /suggest-an-item/. Re-run safe: removes any prior CTA
  card (marker) before appending a fresh one. Leaves the price board card untouched.
#>
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
$slug = 'omaha-grocery-prices'
$jwt = New-GhostJWT $adminKey
$page = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$slug/?formats=lexical" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}).posts[0]
$lexObj = $page.lexical | ConvertFrom-Json

$cta = '<!--SMP-SUGGEST-CTA--><div style="max-width:720px;margin:2.4rem auto 0;text-align:center;background:#f6f1e7;border:1px solid #e2e8f0;border-radius:14px;padding:24px 20px;">' +
  '<p style="margin:0 0 4px;font-weight:800;color:#16263f;font-size:1.2rem;">See a better price somewhere?</p>' +
  '<p style="margin:0 0 16px;color:#3a4658;">Tell us the store, item, and product link and we&#39;ll look at adding it to the board.</p>' +
  '<a href="/suggest-an-item/" style="display:inline-block;background:#e2a43c;color:#16263f;font-weight:800;text-decoration:none;padding:13px 24px;border-radius:10px;">Suggest an item &rarr;</a>' +
  '</div><!--/SMP-SUGGEST-CTA-->'

# rebuild children: drop any existing CTA card, keep the rest, then append fresh CTA
$kept = @()
foreach ($c in $lexObj.root.children) {
  if ($c.type -eq 'html' -and ([string]$c.html) -match 'SMP-SUGGEST-CTA') { continue }
  $kept += $c
}
$kept += [ordered]@{ type='html'; version=1; html=$cta }
$lexObj.root.children = $kept

$lex = ConvertTo-Json $lexObj -Depth 20 -Compress
$payload = @{ posts=@([ordered]@{ lexical=$lex; updated_at=$page.updated_at }) }
$bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $payload -Depth 20))
$jwt2 = New-GhostJWT $adminKey
Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/$($page.id)/" -Method Put -Headers @{Authorization="Ghost $jwt2";'Accept-Version'='v5.0'} -ContentType 'application/json' -Body $bytes | Out-Null
Write-Host ("CTA added to /$slug/  (cards now: " + $kept.Count + ")") -ForegroundColor Green
