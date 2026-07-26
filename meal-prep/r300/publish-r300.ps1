# publish-r300.ps1 - Publishes built recipe cards as PAID posts (tag Meal Prep), upsert by slug.
# Usage: publish-r300.ps1 [-Slugs slug1,slug2] [-All] [-VerifyOnly] [-Max N]
# After each publish: fetches the PUBLIC page and verifies title + paywall + JSON-LD. Never silent.
#
# PORT OF r100\publish-r100.ps1. The publish mechanics are unchanged and deliberately so:
#   * single lexical HTML card (scaler block + prose). NEVER PUT ?source=html - it strips the scaler script.
#   * upsert by slug, status published, visibility paid, tag Meal Prep, custom_excerpt + meta from head.
#   * codeinjection_head carries the Recipe JSON-LD + the paywall Article schema.
# R300 deltas: -Max caps a run (batch publishing per RUN-STATE), the built body/head must exist for every
# requested slug before ANYTHING is sent (no half-published batch), and the run refuses to publish a slug
# that is not in specs-ready.txt.
param([string[]]$Slugs, [switch]$All, [switch]$VerifyOnly, [int]$Max = 0)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$apiUrl = 'https://map-to-success.ghost.io'
$pubBase = 'https://www.thriftycrew.com'
$adminKey = (Get-Content (Join-Path $here '..\.ghostkey') -Raw).Trim()

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

$readyList = @(Get-Content (Join-Path $here 'specs-ready.txt') | Where-Object { $_ })
$readySet=@{}; foreach($s in $readyList){ $readySet[$s]=1 }
if($All){ $Slugs = $readyList }
if(-not $Slugs){ throw 'no slugs' }
if($Max -gt 0 -and $Slugs.Count -gt $Max){ $Slugs = $Slugs | Select-Object -First $Max }

# pre-flight: every requested slug must be guard-approved AND fully built before anything is sent
$pre=@()
foreach($slug in $Slugs){
  if(-not $readySet.ContainsKey($slug)){ $pre += "$slug not in specs-ready.txt" }
  foreach($f in @("specs\$slug.json","built\$slug.body.html","built\$slug.head.html")){
    if(-not (Test-Path (Join-Path $here $f))){ $pre += "$slug missing $f" }
  }
}
if($pre.Count -gt 0){ $pre | ForEach-Object { Write-Output ('PREFLIGHT :: ' + $_) }; throw ('preflight failed on ' + $pre.Count + ' items - nothing published') }

$ok=0; $failed=@()
foreach($slug in $Slugs){
  $spec = Get-Content (Join-Path $here "specs\$slug.json") -Raw | ConvertFrom-Json
  $body = [IO.File]::ReadAllText((Join-Path $here "built\$slug.body.html"), [Text.Encoding]::UTF8)
  $head = [IO.File]::ReadAllText((Join-Path $here "built\$slug.head.html"), [Text.Encoding]::UTF8)
  if(-not $VerifyOnly){
    $lexObj = @{ root = [ordered]@{ children=@([ordered]@{ type='html'; version=1; html=[string]$body }); direction=$null; format=''; indent=0; type='root'; version=1 } }
    $lex = ConvertTo-Json $lexObj -Depth 12 -Compress
    $jwt = New-GhostJWT $adminKey
    $hdr = @{ Authorization="Ghost $jwt"; 'Accept-Version'='v5.0'; 'Content-Type'='application/json' }
    $existing = $null
    try { $existing = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$slug/?fields=id,updated_at,visibility" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -TimeoutSec 30).posts[0] } catch {}
    # PRESERVE visibility on update: visibility is owned by the free-dinner rotation (rotate-free-dinners.ps1),
    # NOT the content publisher. Forcing 'paid' here clobbered this week's free cards back to paid (2026-07-26).
    # Existing post -> keep whatever it is now; only a brand-new post defaults to paid.
    $vis = if($existing -and $existing.visibility){ [string]$existing.visibility } else { 'paid' }
    $postObj = [ordered]@{
      title=$spec.name; slug=$slug; lexical=$lex; status='published'; visibility=$vis
      tags=@(@{name='Meal Prep'})
      custom_excerpt=([string]$spec.head.description)
      codeinjection_head=$head
      meta_title=($spec.name + ' | Thrifty Crew')
      meta_description=[string]$spec.head.description
    }
    if($existing){
      $postObj.updated_at = $existing.updated_at
      $bodyJson = @{ posts=@($postObj) } | ConvertTo-Json -Depth 14
      Invoke-RestMethod -Method PUT -Uri "$apiUrl/ghost/api/admin/posts/$($existing.id)/" -Headers $hdr -Body ([Text.Encoding]::UTF8.GetBytes($bodyJson)) -TimeoutSec 60 | Out-Null
    } else {
      $bodyJson = @{ posts=@($postObj) } | ConvertTo-Json -Depth 14
      Invoke-RestMethod -Method POST -Uri "$apiUrl/ghost/api/admin/posts/" -Headers $hdr -Body ([Text.Encoding]::UTF8.GetBytes($bodyJson)) -TimeoutSec 60 | Out-Null
    }
  }
  # live verify (public page: title present; paid gate = content NOT fully public; schema present)
  Start-Sleep -Milliseconds 400
  try {
    $pub = Invoke-WebRequest -Uri "$pubBase/$slug/" -UseBasicParsing -TimeoutSec 30
    $html = $pub.Content
    $titleOk = $html -match [regex]::Escape([System.Net.WebUtility]::HtmlEncode($spec.name).Replace('&#39;',''))
    if(-not $titleOk){ $titleOk = $html -match [regex]::Escape(($spec.name -split ' ')[0]) }
    $paywalled = ($html -notmatch 'True shopping cost')   # paid content must NOT leak publicly
    $schemaOk = ($html -match 'application/ld\+json')
    if($titleOk -and $paywalled -and $schemaOk){ $ok++; Write-Output ("OK  $slug") }
    else { $failed += $slug; Write-Output ("VERIFY FAIL  $slug  (title=$titleOk paywalled=$paywalled schema=$schemaOk)") }
  } catch { $failed += $slug; Write-Output ("FETCH FAIL  $slug :: " + $_.Exception.Message) }
}
Write-Output ("published+verified OK: $ok / $($Slugs.Count)")
if($failed){ Write-Output ("FAILED: " + ($failed -join ', ')) }
