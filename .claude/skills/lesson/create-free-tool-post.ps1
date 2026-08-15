<#
  create-free-tool-post.ps1 - parameterized creator for FREE (public) interactive tool posts.
  Lexical html card (never ?source=html - it strips scripts). Aborts if the slug exists.
  Usage: create-free-tool-post.ps1 -Slug x -Title "X" -HtmlFile path -MetaTitle "..." -MetaDesc "..." -Excerpt "..."
#>
param(
  [Parameter(Mandatory=$true)][string]$Slug,
  [Parameter(Mandatory=$true)][string]$Title,
  [Parameter(Mandatory=$true)][string]$HtmlFile,
  [Parameter(Mandatory=$true)][string]$MetaTitle,
  [Parameter(Mandatory=$true)][string]$MetaDesc,
  [Parameter(Mandatory=$true)][string]$Excerpt
)
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
$html = [IO.File]::ReadAllText($HtmlFile, [Text.Encoding]::UTF8)
if ($html -notmatch '</script>\s*</div>\s*$') { Write-Host "WARNING: $HtmlFile does not end with </script></div>" -ForegroundColor Yellow }
$jwt = New-GhostJWT $adminKey
$exists = $null
try { $exists = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$Slug/?fields=id" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}).posts[0] } catch {}
if ($exists) { Write-Host "A post already exists at /$Slug/ (id=$($exists.id)). Aborting." -ForegroundColor Yellow; exit 1 }
$lexObj = @{ root = [ordered]@{ children=@([ordered]@{ type='html'; version=1; html=[string]$html }); direction=$null; format=''; indent=0; type='root'; version=1 } }
$lex = ConvertTo-Json $lexObj -Depth 12 -Compress
$postObj = [ordered]@{
  title=$Title; slug=$Slug; lexical=$lex; status='published'; visibility='public';
  custom_excerpt=$Excerpt; meta_title=$MetaTitle; meta_description=$MetaDesc;
  og_title=$Title; og_description=$MetaDesc; twitter_title=$Title; twitter_description=$MetaDesc;
  tags=@(@{name='Tools'})
}
$bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json @{ posts=@($postObj) } -Depth 16))
$jwt2 = New-GhostJWT $adminKey
$res = Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/" -Method Post -Headers @{Authorization="Ghost $jwt2";'Accept-Version'='v5.0'} -ContentType 'application/json' -Body $bytes
$p = $res.posts[0]
Write-Host ("CREATED /{0}/  status={1}  visibility={2}  url={3}" -f $p.slug, $p.status, $p.visibility, $p.url) -ForegroundColor Green
