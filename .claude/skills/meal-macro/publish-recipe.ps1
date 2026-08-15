<#
  publish-recipe.ps1  -  Publishes ONE recipe to the Meal Prep section (tag: Meal Prep).
  Adapted from the lesson skill's publish-resource.ps1. Uses a lexical HTML card so
  styling survives. Paid-gated by default. If -HeadFile is given, its contents become
  codeinjection_head (use it for Recipe JSON-LD); otherwise a paywall schema is added
  for non-public posts. Upserts by slug (safe to re-run).
#>
param(
  [Parameter(Mandatory=$true)][string]$Title,
  [Parameter(Mandatory=$true)][string]$Slug,
  [Parameter(Mandatory=$true)][string]$HtmlFile,
  [Parameter(Mandatory=$true)][string]$Excerpt,
  [Parameter(Mandatory=$true)][string]$MetaTitle,
  [Parameter(Mandatory=$true)][string]$MetaDesc,
  [string]$HeadFile = '',
  [ValidateSet('paid','public','members')][string]$Visibility = 'paid',
  [switch]$Draft
)
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\lesson\ghost-config.ps1"

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

if (-not (Test-Path $HtmlFile)) { throw "HtmlFile not found: $HtmlFile" }
$html = [IO.File]::ReadAllText($HtmlFile, [Text.Encoding]::UTF8)
if ([string]::IsNullOrWhiteSpace($html)) { throw "HtmlFile is empty: $HtmlFile" }

$postUrl = "$apiUrl/$Slug/"
$cih = ''
if ($HeadFile -ne '' -and (Test-Path $HeadFile)) {
  $cih = [IO.File]::ReadAllText($HeadFile, [Text.Encoding]::UTF8).Trim()
} elseif ($Visibility -ne 'public') {
  $pw = [ordered]@{ '@context'='https://schema.org'; '@type'='Article'; isAccessibleForFree=$false;
    hasPart=[ordered]@{ '@type'='WebPageElement'; isAccessibleForFree=$false; cssSelector='.gh-content' };
    mainEntityOfPage=$postUrl; headline=$Title }
  $cih = '<script type="application/ld+json">' + (ConvertTo-Json $pw -Compress -Depth 6) + '</script>'
}

$status = if ($Draft) { 'draft' } else { 'published' }

$jwt = New-GhostJWT $adminKey
$existing = $null
try { $existing = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$Slug/?fields=id,updated_at" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}).posts[0] } catch {}

$lexObj = @{ root = [ordered]@{ children=@([ordered]@{ type='html'; version=1; html=[string]$html }); direction=$null; format=''; indent=0; type='root'; version=1 } }
$lex = ConvertTo-Json $lexObj -Depth 12 -Compress

$postObj = [ordered]@{
  title=$Title; slug=$Slug; lexical=$lex; status=$status; visibility=$Visibility;
  custom_excerpt=$Excerpt; tags=@(@{ name='Meal Prep' });
  meta_title=$MetaTitle; meta_description=$MetaDesc;
  og_title=$MetaTitle; og_description=$MetaDesc; twitter_title=$MetaTitle; twitter_description=$MetaDesc;
  codeinjection_head=$cih
}

if ($existing) { $postObj.updated_at=$existing.updated_at; $method='Put'; $uri="$apiUrl/ghost/api/admin/posts/$($existing.id)/" }
else { $method='Post'; $uri="$apiUrl/ghost/api/admin/posts/" }

$payload = @{ posts = @($postObj) }
$bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $payload -Depth 14))
$jwt = New-GhostJWT $adminKey
$r = Invoke-RestMethod -Uri $uri -Method $method -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -ContentType 'application/json' -Body $bytes -TimeoutSec 30
$saved = $r.posts[0]
$verb = if ($existing) { "UPDATED" } else { "CREATED" }
Write-Host ("{0}: {1}" -f $verb, $postUrl) -ForegroundColor Green
Write-Host ("  status={0}  visibility={1}  tag=Meal Prep  recipeSchema={2}" -f $saved.status, $saved.visibility, [bool]$cih)
