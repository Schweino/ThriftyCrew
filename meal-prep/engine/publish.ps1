# publish.ps1 (engine) - Publishes built recipe cards as PAID posts (tag Meal Prep), upsert by slug.
# Usage: publish.ps1 [-Slugs slug1,slug2] [-All] [-VerifyOnly] [-Force] [-Resume]
# After each publish: fetches the PUBLIC page and verifies title + paywall presence. Never silent.
#
# SCALE HARDENING (2026-07-26, ready for 1000-recipe imports):
#  - Every HTTP call goes through Invoke-GhostApi (timeout + 3-retry backoff on 429/5xx/timeout).
#  - PER-SLUG failure isolation: one bad post no longer aborts the remaining N-1 (was $EAP=Stop over a
#    bare PUT/POST - post 400 of 1000 hitting a 503 killed 400..1000). Failures collect into a FAILED list.
#  - DUPLICATE-SLUG hole closed: the existence GET now distinguishes 404 (genuinely new -> POST) from a
#    transport/5xx error (skip the slug; a swallowed error used to POST and mint a paid <slug>-2 orphan).
#  - CHANGE GATE + RESUME: a SHA1 of the published content is recorded per slug ONLY after a successful
#    verify (db\published-hashes.json). A re-run skips slugs whose built bytes are unchanged, so an
#    interrupted 1000-post run just re-runs (done slugs skip, failed/changed ones republish). -Force
#    republishes regardless; -Resume is an alias kept for discoverability (the hash gate already resumes).
param([string[]]$Slugs, [switch]$All, [switch]$VerifyOnly, [switch]$Force, [switch]$Resume)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path $here -Parent
$apiUrl = 'https://map-to-success.ghost.io'
$pubBase = 'https://www.thriftycrew.com'
$adminKey = (Get-Content (Join-Path $here '..\.ghostkey') -Raw).Trim()
. (Join-Path $PSScriptRoot '..\..\lib\ghost-lib.ps1')   # Get-GhostJWT + Invoke-GhostApi (timeout/retry)
function New-GhostJWT { Get-GhostJWT -Key $adminKey }
function Get-ContentHash([string]$s){ $sha=[System.Security.Cryptography.SHA1]::Create(); return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) -replace '-','') }

if($All){ $Slugs = (Get-ChildItem (Join-Path $root 'db\built\*.body.html')).BaseName -replace '\.body$','' }
if(-not $Slugs){ throw 'no slugs' }

# published-content hashes (the change gate + resume journal in one file)
$hashFile = Join-Path $root 'db\published-hashes.json'
$pubHashes = @{}
if(Test-Path $hashFile){ try { $o=(Get-Content $hashFile -Raw | ConvertFrom-Json); foreach($p in $o.PSObject.Properties){ $pubHashes[$p.Name]=[string]$p.Value } } catch {} }

$ok=0; $skipped=0; $failed=@()
foreach($slug in $Slugs){
  $spec = Get-Content (Join-Path $root "db\recipes\$slug.json") -Raw | ConvertFrom-Json
  $body = [IO.File]::ReadAllText((Join-Path $root "db\built\$slug.body.html"), [Text.Encoding]::UTF8)
  $head = [IO.File]::ReadAllText((Join-Path $root "db\built\$slug.head.html"), [Text.Encoding]::UTF8)
  $desc = [string]$spec.head.description
  $contentHash = Get-ContentHash ($body + "`0" + $head + "`0" + [string]$spec.name + "`0" + $desc)

  $existing = $null
  if(-not $VerifyOnly){
    # existence GET: 404 => genuinely new (POST); any OTHER error (after the wrapper's retries) => do NOT
    # POST (that would risk a duplicate <slug>-2) - skip the slug and report it.
    try {
      $jwt = New-GhostJWT
      $existing = (Invoke-GhostApi -Uri "$apiUrl/ghost/api/admin/posts/slug/$slug/?fields=id,updated_at,visibility" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}).posts[0]
    } catch {
      $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
      if($code -eq 404){ $existing = $null }
      else { $failed += $slug; Write-Output ("GET FAIL  $slug  (existence check errored $code - skipped so no duplicate is created)"); continue }
    }
    # CHANGE GATE: an existing post whose content bytes match the last verified publish is skipped
    # (visibility is deliberately NOT in the hash - the rotation owns it and its flip is not a content change).
    if($existing -and (-not $Force) -and ($pubHashes[$slug] -eq $contentHash)){ $skipped++; Write-Output ("UNCHANGED  $slug"); continue }

    $lexObj = @{ root = [ordered]@{ children=@([ordered]@{ type='html'; version=1; html=[string]$body }); direction=$null; format=''; indent=0; type='root'; version=1 } }
    $lex = ConvertTo-Json $lexObj -Depth 12 -Compress
    $jwt = New-GhostJWT
    $hdr = @{ Authorization="Ghost $jwt"; 'Accept-Version'='v5.0'; 'Content-Type'='application/json' }
    # PRESERVE visibility on update (owned by rotate-free-dinners, not the content publisher). New post -> paid.
    $vis = if($existing -and $existing.visibility){ [string]$existing.visibility } else { 'paid' }
    $postObj = [ordered]@{
      title=$spec.name; slug=$slug; lexical=$lex; status='published'; visibility=$vis
      tags=@(@{name='Meal Prep'})
      custom_excerpt=$desc
      codeinjection_head=$head
      meta_title=($spec.name + ' | Thrifty Crew')
      meta_description=$desc
    }
    try {
      if($existing){
        $postObj.updated_at = $existing.updated_at
        $bodyJson = @{ posts=@($postObj) } | ConvertTo-Json -Depth 14
        Invoke-GhostApi -Method PUT -Uri "$apiUrl/ghost/api/admin/posts/$($existing.id)/" -Headers $hdr -Body ([Text.Encoding]::UTF8.GetBytes($bodyJson)) -TimeoutSec 60 | Out-Null
      } else {
        $bodyJson = @{ posts=@($postObj) } | ConvertTo-Json -Depth 14
        Invoke-GhostApi -Method POST -Uri "$apiUrl/ghost/api/admin/posts/" -Headers $hdr -Body ([Text.Encoding]::UTF8.GetBytes($bodyJson)) -TimeoutSec 60 | Out-Null
      }
    } catch {
      $failed += $slug; Write-Output ("PUBLISH FAIL  $slug :: " + $_.Exception.Message); continue
    }
  }
  # live verify (public page: title present; paid gate = content NOT fully public)
  Start-Sleep -Milliseconds 400
  try {
    $pub = Invoke-GhostApi -Uri "$pubBase/$slug/" -Web -BasicParsing -TimeoutSec 30
    $html = $pub.Content
    $titleOk = $html -match [regex]::Escape([System.Net.WebUtility]::HtmlEncode($spec.name).Replace('&#39;',''))
    if(-not $titleOk){ $titleOk = $html -match [regex]::Escape(($spec.name -split ' ')[0]) }
    # paid content must NOT leak publicly. v2 anchor: 'What This Batch Costs' only in the PAID body.
    # Exemption uses the LIVE post's visibility (rotation flips free cards weekly; spec.visibility is a stale default).
    $liveVis = if($existing -and $existing.visibility){ [string]$existing.visibility } else { [string]$spec.visibility }
    $paywalled = if($liveVis -eq 'public'){ $true } else { ($html -notmatch 'What This Batch Costs') }
    $schemaOk = ($html -match 'application/ld\+json')
    if($titleOk -and $paywalled -and $schemaOk){ $ok++; $pubHashes[$slug]=$contentHash; Write-Output ("OK  $slug") }
    else { $failed += $slug; Write-Output ("VERIFY FAIL  $slug  (title=$titleOk paywalled=$paywalled schema=$schemaOk)") }
  } catch { $failed += $slug; Write-Output ("FETCH FAIL  $slug :: " + $_.Exception.Message) }
}
# persist the change-gate/resume journal (only verified-good slugs advanced their hash above)
if(-not $VerifyOnly){ ($pubHashes | ConvertTo-Json) | Set-Content $hashFile -Encoding UTF8 }
Write-Output ("published+verified OK: $ok / $($Slugs.Count)   (skipped-unchanged: $skipped)")
if($failed){ Write-Output ("FAILED (" + $failed.Count + "): " + ($failed -join ', ')) }
