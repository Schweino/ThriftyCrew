<#
  create-sub-tool-post.ps1  -  Creates the NEW paid "Subscription Tracker" member tool post
  and loads the interactive tool HTML into it as a lexical html card, matching the other 4 tools.
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

$html = Get-Content "C:\Codex\ThriftyCrew\subscription-tracker-tool.html" -Raw
$slug = "subscription-tracker"
$title = "Subscription Tracker"
$metaTitle = "Subscription Tracker - See What They Really Cost You | Thrifty Crew"
$metaDesc = "See what your subscriptions really cost per year, and exactly how much you save by canceling the ones you forgot about. A free interactive tool from Thrifty Crew."
$excerpt = "List every subscription once. This tool shows the real yearly total, ranks the biggest ones, and hands you a printable cancel list with your savings."

# Guard: does a post already exist at this slug?
$jwt = New-GhostJWT $adminKey
$exists = $null
try { $exists = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$slug/?fields=id" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}).posts[0] } catch {}
if ($exists) { Write-Host "A post already exists at /$slug/ (id=$($exists.id)). Aborting create to avoid a duplicate." -ForegroundColor Yellow; exit 1 }

$lexObj = @{ root = [ordered]@{ children=@([ordered]@{ type='html'; version=1; html=[string]$html }); direction=$null; format=''; indent=0; type='root'; version=1 } }
$lex = ConvertTo-Json $lexObj -Depth 12 -Compress

$postObj = [ordered]@{
  title=$title; slug=$slug; lexical=$lex; status='published'; visibility='paid';
  custom_excerpt=$excerpt; meta_title=$metaTitle; meta_description=$metaDesc;
  og_title=$metaTitle; og_description=$metaDesc; twitter_title=$metaTitle; twitter_description=$metaDesc;
  tags=@(@{name='Tools'})
}
$bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json @{ posts=@($postObj) } -Depth 16))
$jwt2 = New-GhostJWT $adminKey
$res = Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/" -Method Post -Headers @{Authorization="Ghost $jwt2";'Accept-Version'='v5.0'} -ContentType 'application/json' -Body $bytes
$p = $res.posts[0]
Write-Host ("CREATED /{0}/  status={1}  visibility={2}  url={3}" -f $p.slug, $p.status, $p.visibility, $p.url) -ForegroundColor Green
