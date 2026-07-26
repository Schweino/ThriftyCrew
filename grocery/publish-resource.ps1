<#
  publish-resource.ps1 (repo-local copy) - Publishes ONE item to the Resources section (tag: resources).
  Uses a lexical HTML card (not source=html) so styled classes like mts-btn survive. Paid-gated by default
  (paywall JSON-LD added), matching the lesson pattern.

  Self-contained for CI: the Ghost admin key comes from $env:GHOST_ADMIN_KEY (GitHub Actions secret) or a
  gitignored .ghostkey file (meal-prep\.ghostkey locally). No out-of-repo sourcing.
#>
param(
  [Parameter(Mandatory=$true)][string]$Title,
  [Parameter(Mandatory=$true)][string]$Slug,
  [Parameter(Mandatory=$true)][string]$HtmlFile,
  [Parameter(Mandatory=$true)][string]$Excerpt,
  [Parameter(Mandatory=$true)][string]$MetaTitle,
  [Parameter(Mandatory=$true)][string]$MetaDesc,
  [ValidateSet('paid','public','members')][string]$Visibility = 'paid',
  [switch]$Draft
)
$ErrorActionPreference = "Stop"
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$adminKey = if ($env:GHOST_ADMIN_KEY) { $env:GHOST_ADMIN_KEY }
  elseif (Test-Path (Join-Path $here '.ghostkey')) { (Get-Content (Join-Path $here '.ghostkey') -Raw).Trim() }
  elseif (Test-Path (Join-Path (Split-Path $here -Parent) 'meal-prep\.ghostkey')) { (Get-Content (Join-Path (Split-Path $here -Parent) 'meal-prep\.ghostkey') -Raw).Trim() }
  else { throw 'Ghost admin key missing: set $env:GHOST_ADMIN_KEY or create meal-prep\.ghostkey' }
$apiUrl = 'https://map-to-success.ghost.io'
. (Join-Path $PSScriptRoot '..\lib\ghost-lib.ps1')   # 2026-07-26: single Ghost helper (was one of 50+ inline copies)
function New-GhostJWT { Get-GhostJWT -Key $adminKey }

if (-not (Test-Path $HtmlFile)) { throw "HtmlFile not found: $HtmlFile" }
$html = [IO.File]::ReadAllText($HtmlFile, [Text.Encoding]::UTF8)
if ([string]::IsNullOrWhiteSpace($html)) { throw "HtmlFile is empty: $HtmlFile" }

$postUrl = "$apiUrl/$Slug/"
$cih = ''
if ($Visibility -ne 'public') {
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
  custom_excerpt=$Excerpt; tags=@(@{ name='Resources' });
  meta_title=$MetaTitle; meta_description=$MetaDesc;
  og_title=$MetaTitle; og_description=$MetaDesc; twitter_title=$MetaTitle; twitter_description=$MetaDesc;
  codeinjection_head=$cih
}

if ($existing) { $postObj.updated_at=$existing.updated_at; $method='Put'; $uri="$apiUrl/ghost/api/admin/posts/$($existing.id)/" }
else { $method='Post'; $uri="$apiUrl/ghost/api/admin/posts/" }

$payload = @{ posts = @($postObj) }
$bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $payload -Depth 14))
$jwt = New-GhostJWT $adminKey
$r = Invoke-RestMethod -Uri $uri -Method $method -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -ContentType 'application/json' -Body $bytes -TimeoutSec 120
$saved = $r.posts[0]
$verb = if ($existing) { "UPDATED" } else { "CREATED" }
Write-Host ("{0}: {1}" -f $verb, $postUrl) -ForegroundColor Green
Write-Host ("  status={0}  visibility={1}  paywallSchema={2}" -f $saved.status, $saved.visibility, [bool]$cih)

