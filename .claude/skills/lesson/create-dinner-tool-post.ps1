<#
  create-dinner-tool-post.ps1  -  Creates the FREE (public) "What's for Dinner Tonight?"
  interactive tool post as a lexical html card (never ?source=html - it strips scripts).
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

$html = [IO.File]::ReadAllText("C:\Codex\ThriftyCrew\dinner-tonight-tool.html", [Text.Encoding]::UTF8)
if ($html -notmatch '</script>\s*</div>\s*$') { Write-Host "WARNING: tool file does not end with </script></div> - check for truncation" -ForegroundColor Yellow }
$slug = "whats-for-dinner-tonight"
$title = "What's for Dinner Tonight?"
$metaTitle = "What's for Dinner Tonight? Free Cheap-Dinner Finder | Thrifty Crew"
$metaDesc = "Tap what's already in your kitchen and get tonight's cheapest dinner ideas - with live Omaha grocery prices for anything you're missing. Free from Thrifty Crew."
$excerpt = "Tap what you have in the kitchen. Get the cheapest dinners you can make tonight, and live store prices for anything you're missing."

$jwt = New-GhostJWT $adminKey
$exists = $null
try { $exists = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$slug/?fields=id" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}).posts[0] } catch {}
if ($exists) { Write-Host "A post already exists at /$slug/ (id=$($exists.id)). Aborting to avoid a duplicate." -ForegroundColor Yellow; exit 1 }

$lexObj = @{ root = [ordered]@{ children=@([ordered]@{ type='html'; version=1; html=[string]$html }); direction=$null; format=''; indent=0; type='root'; version=1 } }
$lex = ConvertTo-Json $lexObj -Depth 12 -Compress

$postObj = [ordered]@{
  title=$title; slug=$slug; lexical=$lex; status='published'; visibility='public';
  custom_excerpt=$excerpt; meta_title=$metaTitle; meta_description=$metaDesc;
  og_title=$title; og_description=$metaDesc; twitter_title=$title; twitter_description=$metaDesc;
  tags=@(@{name='Tools'})
}
$bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json @{ posts=@($postObj) } -Depth 16))
$jwt2 = New-GhostJWT $adminKey
$res = Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/" -Method Post -Headers @{Authorization="Ghost $jwt2";'Accept-Version'='v5.0'} -ContentType 'application/json' -Body $bytes
$p = $res.posts[0]
Write-Host ("CREATED /{0}/  status={1}  visibility={2}  url={3}" -f $p.slug, $p.status, $p.visibility, $p.url) -ForegroundColor Green