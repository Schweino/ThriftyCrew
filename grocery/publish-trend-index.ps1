<#
  publish-trend-index.ps1 - Publishes out\trend\index.html to /omaha-price-tracker/.

  Replaces archive\publish-tracker-index.ps1, which was a one-off with an inline JWT copy and no way to
  update the post's meta. That is how the live page ended up stuck on "29 Staples Tracked Weekly" from
  10 Jul while the fragment underneath moved on: the fragment was republishable, the TITLE was not, so
  the count in meta_title/meta_description silently went stale.

  The count is now DERIVED from the keep-list (lib\trend-keep.ps1), never typed in. If the keep-list
  changes, the meta follows on the next publish.

  Publishes via the lexical single-html-card (Get-GhostLexical), never ?source=html - see the recipe
  notes: ?source=html strips scripts.

  Usage: powershell -ExecutionPolicy Bypass -File publish-trend-index.ps1 [-WhatIf]
#>
param([switch]$WhatIf)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $here '..\lib\ghost-lib.ps1')
. (Join-Path $here '..\lib\trend-keep.ps1')

$apiUrl = 'https://map-to-success.ghost.io'
$slug   = 'omaha-price-tracker'
$frag   = [IO.File]::ReadAllText((Join-Path $here 'out\trend\index.html'), [Text.Encoding]::UTF8)

# Guards carried over from the one-off, plus a count check the old script could not do.
if ([regex]::IsMatch($frag, '\bsix\b')) { throw 'Refusing to publish: index fragment still contains the word "six".' }
if (-not $frag.Contains('Fareway'))     { throw 'Refusing to publish: index fragment missing Fareway.' }

$n = (Get-TrendKeep).Count
$linksInFrag = ([regex]::Matches($frag, '-price-omaha/')).Count
if ($linksInFrag -ne $n) { throw ("Refusing to publish: fragment links to {0} pages but the keep-list has {1}. Re-run build-trend-index.ps1." -f $linksInFrag, $n) }

$metaTitle = ("Omaha Grocery Price Tracker - {0} Staples Tracked Weekly | Thrifty Crew" -f $n)
$metaDesc  = ("Week-by-week price history for {0} grocery staples across seven Omaha stores. Current cheapest, record lows, and whether now is a good week to buy." -f $n)

$key = Get-GhostKey -Root (Split-Path $here -Parent)
$jwt = Get-GhostJWT -Key $key
$h   = @{ Authorization = "Ghost $jwt"; 'Accept-Version' = 'v5.0' }

$cur = (Invoke-GhostApi -Uri "$apiUrl/ghost/api/admin/posts/slug/$slug/?fields=id,title,status,updated_at" -Headers $h).posts[0]
if (-not $cur) { throw "post /$slug/ not found" }

Write-Host ("fragment: {0} links   meta count -> {1}" -f $linksInFrag, $n) -ForegroundColor Cyan
if ($WhatIf) { Write-Host ("WHATIF would update /{0}/ (status={1})" -f $slug, $cur.status); exit 0 }

$postObj = [ordered]@{
  lexical          = (Get-GhostLexical -Html $frag)
  meta_title       = $metaTitle
  meta_description = $metaDesc
  updated_at       = $cur.updated_at
}
$bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json @{ posts = @($postObj) } -Depth 14))
$saved = (Invoke-GhostApi -Method PUT -Uri "$apiUrl/ghost/api/admin/posts/$($cur.id)/" -Headers ($h + @{ 'Content-Type' = 'application/json' }) -Body $bytes).posts[0]

Write-Host ("UPDATED /{0}/  status={1} visibility={2}" -f $slug, $saved.status, $saved.visibility) -ForegroundColor Green
Write-Host ("  meta_title: {0}" -f $saved.meta_title)
