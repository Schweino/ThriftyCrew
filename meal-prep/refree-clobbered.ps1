# refree-clobbered.ps1 - one-off repair: the r100/r300 batch republish (publish-*.ps1) forces
# visibility='paid', which clobbered this week's free-dinner-rotation cards back to paid. This flips
# every slug in free-rotation.json that is currently paid back to 'public' using the SAME minimal PUT
# the rotation uses (visibility + updated_at only - content/tags/lexical untouched), and re-syncs
# recipes-db.visibility. Idempotent: already-public slugs are skipped.
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$apiUrl='https://map-to-success.ghost.io'
$adminKey=(Get-Content (Join-Path $here '.ghostkey') -Raw).Trim()
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage

function JWT { $p=$adminKey -split ':'; $sb=New-Object byte[] ($p[1].Length/2); for($i=0;$i -lt $sb.Length;$i++){ $sb[$i]=[Convert]::ToByte($p[1].Substring($i*2,2),16) }; $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $h='{"alg":"HS256","typ":"JWT","kid":"'+$p[0]+'"}'; $pl='{"iat":'+$now+',"exp":'+($now+300)+',"aud":"/admin/"}'; $b={param($b)[Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_')}; $si=(& $b ([Text.Encoding]::UTF8.GetBytes($h)))+'.'+(& $b ([Text.Encoding]::UTF8.GetBytes($pl))); $hm=New-Object System.Security.Cryptography.HMACSHA256 (,$sb); $si+'.'+(& $b ($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes($si)))) }

$fr = Read-JsonFile (Join-Path $here 'free-rotation.json')
$flipped=@(); $already=@(); $failed=@()
foreach($f in $fr.free){
  $slug=[string]$f.slug
  try{
    $jwt=JWT
    $p=(Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$slug/?fields=id,visibility,updated_at" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -TimeoutSec 30).posts[0]
    if([string]$p.visibility -eq 'public'){ $already+=$slug; continue }
    $body=@{ posts=@(@{ visibility='public'; updated_at=[string]$p.updated_at }) } | ConvertTo-Json -Depth 4
    [void](Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/$($p.id)/" -Method Put -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -ContentType 'application/json' -Body $body -TimeoutSec 60)
    $flipped+=$slug
    Write-Output ("  freed: {0}  (was {1})" -f $slug, $p.visibility)
  } catch { $failed+=$slug; Write-Output ("  FAIL: {0} :: {1}" -f $slug, $_.Exception.Message) }
}
# Check recipes-db.visibility agreement - REPORT ONLY. Never re-serialize the 1.6MB db with
# ConvertTo-Json (PS5.1 OOM/corruption trap). publish-*.ps1 does not touch recipes-db, so these rows
# should already read public from the rotation; if any disagree, they are listed for a surgical fix.
$dbPath = Join-Path $here 'recipes-db.json'
$db = Get-Content $dbPath -Raw -Encoding utf8 | ConvertFrom-Json
$bySlug=@{}; foreach($r in $db.recipes){ if($r.slug){ $bySlug[[string]$r.slug]=$r } }
$dbMismatch=@()
foreach($f in $fr.free){ $s=[string]$f.slug; if($bySlug.ContainsKey($s) -and [string]$bySlug[$s].visibility -ne 'public'){ $dbMismatch+=$s } }
if($dbMismatch.Count -gt 0){ Write-Output ("recipes-db visibility MISMATCH (still not public): " + ($dbMismatch -join ', ')) } else { Write-Output "recipes-db visibility: all free slugs already public (in sync)" }
Write-Output ("`nflipped-to-public: {0}   already-public: {1}   failed: {2}" -f $flipped.Count, $already.Count, $failed.Count)
if($failed.Count){ Write-Output ("FAILED: " + ($failed -join ', ')) }
