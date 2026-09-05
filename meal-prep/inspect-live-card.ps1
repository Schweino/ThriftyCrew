# inspect-live-card.ps1 - GET a published post's HTML via Ghost Admin API and report the visible
# Ingredients-list items vs the recipes-db ground-truth ingredient set, plus whether it carries the
# grouped "Pantry seasonings (...)" cost line. Read-only. Usage: inspect-live-card.ps1 slug1 slug2 ...
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Slugs)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$apiUrl = 'https://map-to-success.ghost.io'
$adminKey = (Get-Content (Join-Path $here '.ghostkey') -Raw).Trim()
$db = (Read-JsonFile (Join-Path $here 'recipes-db.json')).recipes
$dbBySlug=@{}; foreach($r in $db){ if($r.slug){ $dbBySlug[$r.slug]=$r } }
. (Join-Path $PSScriptRoot '..\lib\ghost-lib.ps1')   # 2026-07-26: single Ghost helper (was one of 50+ inline copies)
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage

function New-GhostJWT { Get-GhostJWT -Key $adminKey }

foreach($slug in $Slugs){
  $jwt = New-GhostJWT $adminKey
  $post = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$slug/?formats=html" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -TimeoutSec 40).posts[0]
  $html = [string]$post.html
  # Ingredients-list items: <li><strong>Name...</strong> that are NOT the cost/total lines
  $liItems = [regex]::Matches($html, '<li>\s*<strong>([^:<]+?)\s*:?\s*</strong>') | ForEach-Object { $_.Groups[1].Value.Trim() }
  $ingNames = $liItems | Where-Object { $_ -notmatch '^(Batch total|True shopping cost|Starting with|Pantry|Per serving|Prep|Cook)' }
  $hasPantryLine = $html -match 'Pantry seasonings\s*\('
  $pantryList = ''
  if($hasPantryLine){ $pantryList = ([regex]::Match($html, 'Pantry seasonings\s*\(([^)]*)\)')).Groups[1].Value }
  $dbIng = @($dbBySlug[$slug].ingredients)
  $scalerCount = ([regex]::Matches($html, 'data-grams=')).Count
  Write-Output ("=== {0} ===" -f $slug)
  Write-Output ("  db ingredients: {0}   card Ingredients <li>: {1}   scaler data-grams: {2}" -f $dbIng.Count, @($ingNames).Count, $scalerCount)
  Write-Output ("  grouped 'Pantry seasonings' cost line: {0}{1}" -f $hasPantryLine, $(if($hasPantryLine){ "  -> ($pantryList)" }else{''}))
  if($dbIng.Count -gt @($ingNames).Count){
    $shown = @{}; $ingNames | ForEach-Object { $shown[$_.ToLower()]=1 }
    $missing = @($dbIng | Where-Object { -not $shown.ContainsKey($_.item.ToLower()) } | ForEach-Object { $_.item })
    Write-Output ("  *** AFFECTED: {0} db item(s) NOT in the visible list: {1}" -f $missing.Count, ($missing -join ', '))
  } else {
    Write-Output ("  OK: visible list covers the db ingredient set")
  }
}
