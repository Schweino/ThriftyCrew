<#
  publish-beta.ps1 - Publishes out/board-v2-embed.html to the beta page/post (slug omaha-grocery-prices-beta)
  as a lexical HTML card, PRESERVING noindex (codeinjection_head robots meta) so the beta never gets crawled.
  Auto-detects whether the slug is a Ghost page or post. Admin JWT auth (content writes work with the key;
  only *settings* are read-only).
#>
param([string]$HtmlFile = "out/board-v2-embed.html")
$ErrorActionPreference = "Stop"
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$slug = 'omaha-grocery-prices-beta'
$apiUrl = 'https://map-to-success.ghost.io'
$noindex = '<meta name="robots" content="noindex, nofollow">'

$adminKey = if ($env:GHOST_ADMIN_KEY) { $env:GHOST_ADMIN_KEY }
  elseif (Test-Path (Join-Path $here '.ghostkey')) { (Get-Content (Join-Path $here '.ghostkey') -Raw).Trim() }
  elseif (Test-Path (Join-Path (Split-Path $here -Parent) 'meal-prep\.ghostkey')) { (Get-Content (Join-Path (Split-Path $here -Parent) 'meal-prep\.ghostkey') -Raw).Trim() }
  else { throw 'Ghost admin key missing: set $env:GHOST_ADMIN_KEY or create meal-prep\.ghostkey' }

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

$hf = if ([IO.Path]::IsPathRooted($HtmlFile)) { $HtmlFile } else { Join-Path $here $HtmlFile }
if (-not (Test-Path $hf)) { throw "HtmlFile not found: $hf" }
$html = [IO.File]::ReadAllText($hf, [Text.Encoding]::UTF8)
if ([string]::IsNullOrWhiteSpace($html)) { throw "HtmlFile is empty: $hf" }

$jwt = New-GhostJWT $adminKey
$hdr = @{ Authorization = "Ghost $jwt"; 'Accept-Version' = 'v5.0' }

# find the resource: try posts, then pages
$kind = $null; $res = $null
try { $res = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$slug/?fields=id,updated_at,status,visibility,codeinjection_head" -Headers $hdr).posts[0]; if ($res) { $kind = 'posts' } } catch {}
if (-not $res) {
  try { $res = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/pages/slug/$slug/?fields=id,updated_at,status,visibility,codeinjection_head" -Headers $hdr).pages[0]; if ($res) { $kind = 'pages' } } catch {}
}
if (-not $res) { throw "No post or page found with slug '$slug'. Create it first." }
Write-Host "Found $kind id=$($res.id) status=$($res.status) visibility=$($res.visibility)"

# preserve any existing head injection but guarantee the noindex meta is present
$cih = [string]$res.codeinjection_head
if ([string]::IsNullOrWhiteSpace($cih)) { $cih = $noindex }
elseif ($cih -notmatch 'noindex') { $cih = $cih.TrimEnd() + "`n" + $noindex }

$lexObj = @{ root = [ordered]@{ children=@([ordered]@{ type='html'; version=1; html=[string]$html }); direction=$null; format=''; indent=0; type='root'; version=1 } }
$lex = ConvertTo-Json $lexObj -Depth 12 -Compress

$body = @{ $kind = @(@{
  id = $res.id
  lexical = $lex
  status = 'published'
  codeinjection_head = $cih
  updated_at = $res.updated_at
}) } | ConvertTo-Json -Depth 14

$fresh = New-GhostJWT $adminKey
$put = Invoke-RestMethod -Method Put -Uri "$apiUrl/ghost/api/admin/$kind/$($res.id)/" `
  -Headers @{ Authorization = "Ghost $fresh"; 'Accept-Version' = 'v5.0'; 'Content-Type' = 'application/json' } `
  -Body ([Text.Encoding]::UTF8.GetBytes($body))
$out = if ($kind -eq 'posts') { $put.posts[0] } else { $put.pages[0] }
Write-Host "PUBLISHED $kind/$slug  status=$($out.status)  url=$($out.url)  (noindex preserved)"
