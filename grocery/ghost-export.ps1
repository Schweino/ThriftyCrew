<#
  ghost-export.ps1 - monthly off-Ghost backup of ALL site content (2026-07-23, improvement item 13).

  Everything price-related is rebuildable from this repo, but hand-authored Ghost content (the 52
  lessons, pages, hub prose) had NO backup outside Ghost itself - a fat-fingered delete or a Ghost-side
  loss would be unrecoverable. This exports every post + page (lexical + html formats, all statuses)
  via the Admin API into site-backups\ghost-export-<yyyy-MM>.json, which the local daily wrapper commits
  monthly. Read-only: this script never writes to Ghost.

  Run standalone anytime, or let run-daily-local.ps1 call it on the 1st of the month.
#>
param([string]$OutDir = "")
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here
$dest = if ($OutDir) { $OutDir } else { Join-Path $repo 'site-backups' }
if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }

$adminKey = if ($env:GHOST_ADMIN_KEY) { $env:GHOST_ADMIN_KEY }
  elseif (Test-Path (Join-Path $repo 'meal-prep\.ghostkey')) { (Get-Content (Join-Path $repo 'meal-prep\.ghostkey') -Raw).Trim() }
  else { throw 'Ghost admin key missing: set $env:GHOST_ADMIN_KEY or create meal-prep\.ghostkey' }
$apiUrl = 'https://map-to-success.ghost.io'
. (Join-Path $PSScriptRoot '..\lib\ghost-lib.ps1')   # 2026-07-26: single Ghost helper (was one of 50+ inline copies)
function New-GhostJWT { Get-GhostJWT -Key $adminKey }

function Get-AllGhost([string]$resource) {
  $all = New-Object System.Collections.Generic.List[object]
  $page = 1
  while ($true) {
    $jwt = New-GhostJWT $adminKey   # fresh token per page; 5-min expiry never bites a long export
    $r = Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/$resource/?formats=lexical,html&limit=50&page=$page&include=tags" `
      -Headers @{ Authorization = "Ghost $jwt"; 'Accept-Version' = 'v5.0' } -TimeoutSec 45
    foreach ($item in $r.$resource) { $all.Add($item) }
    $pg = $r.meta.pagination
    if (-not $pg -or -not $pg.next) { break }
    $page = [int]$pg.next
    Start-Sleep -Milliseconds 300
  }
  return $all
}

$stamp = (Get-Date).ToString('yyyy-MM')
$outFile = Join-Path $dest ("ghost-export-$stamp.json")
$posts = Get-AllGhost 'posts'
$pages = Get-AllGhost 'pages'
# manual JSON assembly is unnecessary here: each item is an API object; a wrapper hashtable with two
# arrays stays well under PS5.1's ConvertTo-Json problem sizes at -Depth 8 for ~600 docs... it does NOT.
# 600 lexical docs is exactly the big-graph OOM class, so write incrementally instead.
$sw = New-Object System.IO.StreamWriter($outFile, $false, (New-Object System.Text.UTF8Encoding($false)))
try {
  $sw.WriteLine('{ "exported": "' + (Get-Date).ToString('s') + '", "posts": [')
  for ($i = 0; $i -lt $posts.Count; $i++) { $sw.Write(($posts[$i] | ConvertTo-Json -Depth 8 -Compress)); if ($i -lt $posts.Count - 1) { $sw.WriteLine(',') } }
  $sw.WriteLine('], "pages": [')
  for ($i = 0; $i -lt $pages.Count; $i++) { $sw.Write(($pages[$i] | ConvertTo-Json -Depth 8 -Compress)); if ($i -lt $pages.Count - 1) { $sw.WriteLine(',') } }
  $sw.WriteLine('] }')
} finally { $sw.Dispose() }
# prove the incremental assembly produced valid JSON before calling it a backup
$null = Get-Content $outFile -Raw | ConvertFrom-Json
# then ZIP it: ~1,100 lexical docs is ~40 MB raw, which would grow the repo ~half a GB a year; the JSON
# compresses ~90%. The zip is the committed artifact; the raw json is removed after a verified compress.
$zipFile = $outFile -replace '\.json$', '.zip'
if (Test-Path $zipFile) { Remove-Item $zipFile -Force }
Compress-Archive -Path $outFile -DestinationPath $zipFile
if ((Get-Item $zipFile).Length -gt 100KB) { Remove-Item $outFile -Force } else { throw "zip suspiciously small - keeping the raw json" }
$mb = [Math]::Round((Get-Item $zipFile).Length/1MB, 1)
Write-Output ("ghost-export: {0} posts + {1} pages -> {2} ({3} MB zipped, parse-verified before compress)" -f $posts.Count, $pages.Count, (Split-Path $zipFile -Leaf), $mb)
