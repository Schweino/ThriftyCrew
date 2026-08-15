# publish-tool-post.ps1 - upserts a tool post's body from its local source html (the standard lexical
# single-html-card method - NEVER ?source=html, it strips scripts). Visibility-PRESERVING on update.
# Usage: .\publish-tool-post.ps1 -Slug money-leak-finder -File ..\tools\leak-finder-tool.html
# (Recreates the never-committed update-tool-post flow; sources live at C:\Codex\ThriftyCrew\site\tools\.)
param([Parameter(Mandatory)][string]$Slug,[Parameter(Mandatory)][string]$File,[switch]$Force)
$ErrorActionPreference='Stop'
# This script lives at site\build\, but everything it reaches for - lib\, meal-prep\, grocery\ - hangs off
# the REPO ROOT. Derive that explicitly rather than anchoring on the script's own directory: before the
# 2026-08-15 restructure the two were the same folder, so every Join-Path below would have silently pointed
# two directories deep into nothing the moment the script moved.
$here = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$apiUrl='https://map-to-success.ghost.io'
# env first so this can run on a runner, where the gitignored key file does not exist
$adminKey= if($env:GHOST_ADMIN_KEY){ $env:GHOST_ADMIN_KEY } else { (Get-Content (Join-Path $here 'meal-prep\.ghostkey') -Raw).Trim() }
. (Join-Path $here 'lib\ghost-lib.ps1')   # 2026-07-26: single Ghost helper (was one of 50+ inline copies)
. (Join-Path $here 'lib\ghost-drift-lib.ps1')
function New-GhostJWT { Get-GhostJWT -Key $adminKey }
$body=[IO.File]::ReadAllText((Resolve-Path $File),[Text.Encoding]::UTF8)
$jwt=New-GhostJWT
$post=(Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$Slug/?fields=id,updated_at,visibility,title" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -TimeoutSec 30).posts[0]
if(-not $post){ throw "post not found: $Slug (this script only updates existing posts)" }

# ---- PRE-FLIGHT: never blind-overwrite a live body nobody looked at (2026-08-08) -------------------------
# This PUT replaces the whole card. If live has drifted from the local source, the drift dies here silently,
# which is exactly what nearly happened to my-crew: 19 live links carried absolute hosts the local file did
# not have, and any unrelated republish would have reverted them with no trace. audit-ghost-drift sweeps for
# this after the fact; the sweep can only ever report damage already done. This is the same check at the one
# moment it can still prevent it - the estate's own lesson that an advisory report is not in the publish path.
# A reviewed difference is recorded in grocery\ghost-drift-allowlist.json and passes without -Force.
$liveBody = Get-GhostCardBody -Api $apiUrl -Key $adminKey -Slug $Slug
$cmp = Compare-ToolBody $body $liveBody
if($cmp.blind){
  Write-Output "  pre-flight: no existing html card on '$Slug' - nothing to overwrite, publishing"
} elseif(-not $cmp.same){
  $allow=@(); $allowF=Join-Path $here 'grocery\ghost-drift-allowlist.json'
  if(Test-Path $allowF){ try { $allow=@((Get-Content $allowF -Raw | ConvertFrom-Json).allow) } catch {} }
  $h = Get-BodyHash $liveBody
  if(Test-Allowlisted $allow $Slug $h){
    Write-Output "  pre-flight: live differs from local but the difference is reviewed (allowlist $h) - publishing"
  } elseif(-not $Force){
    $lm = if($cmp.localMid.Length -gt 200){ $cmp.localMid.Substring(0,200)+'...' } else { $cmp.localMid }
    $vm = if($cmp.liveMid.Length  -gt 200){ $cmp.liveMid.Substring(0,200)+'...'  } else { $cmp.liveMid }
    Write-Output ("REFUSING to publish '{0}': the LIVE body differs from {1} by {2:+#;-#;0} byte(s), first at char {3}." -f $Slug,(Split-Path $File -Leaf),$cmp.delta,$cmp.prefix)
    Write-Output ("  local: [" + $lm + "]")
    Write-Output ("  live : [" + $vm + "]")
    Write-Output '  Publishing would DELETE that live-only content. Either fold it into the local source, or'
    Write-Output ("  record it as reviewed: grocery\audit-ghost-drift.ps1 -Accept {0}   (then re-run)." -f $Slug)
    Write-Output '  If you have looked and mean to overwrite it anyway, re-run with -Force.'
    exit 2
  } else {
    Write-Output ("  pre-flight: live differs by {0:+#;-#;0} byte(s) and -Force was given - OVERWRITING it" -f $cmp.delta)
  }
}
$lexObj=@{root=[ordered]@{children=@([ordered]@{type='html';version=1;html=$body});direction=$null;format='';indent=0;type='root';version=1}}
$lex=ConvertTo-Json $lexObj -Depth 12 -Compress
$payload=@{posts=@(@{lexical=$lex;updated_at=$post.updated_at})} | ConvertTo-Json -Depth 8
$jwt=New-GhostJWT
Invoke-RestMethod -Method PUT -Uri "$apiUrl/ghost/api/admin/posts/$($post.id)/" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0';'Content-Type'='application/json'} -Body ([Text.Encoding]::UTF8.GetBytes($payload)) -TimeoutSec 60 | Out-Null
Write-Output ("updated '{0}' ({1}) from {2} - visibility untouched ({3})" -f $post.title,$Slug,(Split-Path $File -Leaf),$post.visibility)