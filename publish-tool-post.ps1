# publish-tool-post.ps1 - upserts a tool post's body from its local source html (the standard lexical
# single-html-card method - NEVER ?source=html, it strips scripts). Visibility-PRESERVING on update.
# Usage: .\publish-tool-post.ps1 -Slug money-leak-finder -File .\leak-finder-tool.html
# (Recreates the never-committed update-tool-post flow; sources live at C:\Codex\income\*-tool.html.)
param([Parameter(Mandatory)][string]$Slug,[Parameter(Mandatory)][string]$File)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$apiUrl='https://map-to-success.ghost.io'
$adminKey=(Get-Content (Join-Path $here 'meal-prep\.ghostkey') -Raw).Trim()
. (Join-Path $PSScriptRoot 'lib\ghost-lib.ps1')   # 2026-07-26: single Ghost helper (was one of 50+ inline copies)
function New-GhostJWT { Get-GhostJWT -Key $adminKey }
$body=[IO.File]::ReadAllText((Resolve-Path $File),[Text.Encoding]::UTF8)
$jwt=New-GhostJWT
$post=(Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$Slug/?fields=id,updated_at,visibility,title" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -TimeoutSec 30).posts[0]
if(-not $post){ throw "post not found: $Slug (this script only updates existing posts)" }
$lexObj=@{root=[ordered]@{children=@([ordered]@{type='html';version=1;html=$body});direction=$null;format='';indent=0;type='root';version=1}}
$lex=ConvertTo-Json $lexObj -Depth 12 -Compress
$payload=@{posts=@(@{lexical=$lex;updated_at=$post.updated_at})} | ConvertTo-Json -Depth 8
$jwt=New-GhostJWT
Invoke-RestMethod -Method PUT -Uri "$apiUrl/ghost/api/admin/posts/$($post.id)/" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0';'Content-Type'='application/json'} -Body ([Text.Encoding]::UTF8.GetBytes($payload)) -TimeoutSec 60 | Out-Null
Write-Output ("updated '{0}' ({1}) from {2} - visibility untouched ({3})" -f $post.title,$Slug,(Split-Path $File -Leaf),$post.visibility)