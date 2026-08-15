<#
  update-tool-post.ps1  -  Replaces the content of an EXISTING post with an interactive
  on-site tool (lexical html card). Used for the member tool suite:
    budget-tracker            <- C:\Codex\ThriftyCrew\budget-tracker-tool.html
    debt-payoff-date-calculator    <- C:\Codex\ThriftyCrew\debt-payoff-tool.html
    compound-interest-calculator   <- C:\Codex\ThriftyCrew\compound-interest-tool.html
    savings-goal-tracker           <- C:\Codex\ThriftyCrew\savings-goal-tool.html
  Usage: update-tool-post.ps1 -Slug <slug> -HtmlFile <path> -MetaTitle "..." -MetaDesc "..." -Excerpt "..."
#>
param(
  [Parameter(Mandatory=$true)][string]$Slug,
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
$html = Get-Content $HtmlFile -Raw
$jwt = New-GhostJWT $adminKey
$po = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$Slug/?fields=id,updated_at" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}).posts[0]
$lexObj = @{ root = [ordered]@{ children=@([ordered]@{ type='html'; version=1; html=[string]$html }); direction=$null; format=''; indent=0; type='root'; version=1 } }
$lex = ConvertTo-Json $lexObj -Depth 12 -Compress
$postObj = [ordered]@{ lexical=$lex; custom_excerpt=$Excerpt; meta_title=$MetaTitle; meta_description=$MetaDesc; og_title=$MetaTitle; og_description=$MetaDesc; twitter_title=$MetaTitle; twitter_description=$MetaDesc; updated_at=$po.updated_at }
$bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json @{ posts=@($postObj) } -Depth 16))
$jwt2 = New-GhostJWT $adminKey
$res = Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/$($po.id)/" -Method Put -Headers @{Authorization="Ghost $jwt2";'Accept-Version'='v5.0'} -ContentType 'application/json' -Body $bytes
Write-Host ("Updated POST /{0}/  visibility={1}" -f $res.posts[0].slug, $res.posts[0].visibility) -ForegroundColor Green
