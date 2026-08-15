<#
  update-budget-tool-post.ps1  -  Replaces the content of the EXISTING /budget-tracker/ POST
  (the old dead Google Sheet resource) with the interactive on-site budget tool.
  Source html: C:\Codex\ThriftyCrew\budget-tracker-tool.html. Keeps slug/visibility/tags.
  Re-run after editing the html file to push updates. (The former build-budget-tool-page.ps1
  approach created a duplicate PAGE at budget-tracker-2 - deleted; do not use.)
#>
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\ghost-config.ps1"
function New-GhostJWT { param($key)
  $p=$key -split ':'; $id=$p[0]; $sh=$p[1]
  $sb=New-Object byte[] ($sh.Length/2)
  for($i=0;$i -lt $sb.Length;$i++){ $sb[$i]=[Convert]::ToByte($sh.Substring($i*2,2),16) }
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $h='{"alg":"HS256","typ":"JWT","kid":"'+$id+'"}'; $pl='{"iat":'+$now+',"exp":'+($now+300)+',"aud":"/admin/"}'
  $b64={param($b)[Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_')}
  $si=(& $b64 ([Text.Encoding]::UTF8.GetBytes($h)))+'.'+(& $b64 ([Text.Encoding]::UTF8.GetBytes($pl)))
  $hm=New-Object System.Security.Cryptography.HMACSHA256 (,$sb); return $si+'.'+(& $b64 ($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes($si))))
}

$html = Get-Content 'C:\Codex\ThriftyCrew\budget-tracker-tool.html' -Raw
$metaTitle = 'Budget Tracker | Thrifty Crew'
$metaDesc  = "See your whole month on one page: money in, money out, and the gap. Sorts every bill onto the right paycheck and builds your debt attack plan. Your numbers never leave your device."
$excerpt   = "Money in, money out, and the gap. Your bills sorted by paycheck and a debt plan, all on one page. Your numbers never leave your device."

$jwt = New-GhostJWT $adminKey
$po = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/budget-tracker/?fields=id,updated_at" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}).posts[0]

$lexObj = @{ root = [ordered]@{ children=@([ordered]@{ type='html'; version=1; html=[string]$html }); direction=$null; format=''; indent=0; type='root'; version=1 } }
$lex = ConvertTo-Json $lexObj -Depth 12 -Compress
$postObj = [ordered]@{ lexical=$lex; custom_excerpt=$excerpt; meta_title=$metaTitle; meta_description=$metaDesc; og_title=$metaTitle; og_description=$metaDesc; twitter_title=$metaTitle; twitter_description=$metaDesc; updated_at=$po.updated_at }

$payload = @{ posts=@($postObj) }
$bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $payload -Depth 16))
$jwt2 = New-GhostJWT $adminKey
$res = Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/$($po.id)/" -Method Put -Headers @{Authorization="Ghost $jwt2";'Accept-Version'='v5.0'} -ContentType 'application/json' -Body $bytes
Write-Host ("Updated POST /{0}/  visibility={1}" -f $res.posts[0].slug, $res.posts[0].visibility) -ForegroundColor Green
