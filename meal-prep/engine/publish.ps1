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
#  - CREATE IS NOT REPUBLISH (2026-08-16). Creating a live paid post is irreversible in a way updating one
#    is not, and until today both went through the same door. propagate-recipes.ps1 carries every DIRTY
#    spec by design, and a wave-3 audit measured that set at 49: 9 wave slugs, 19 republishes, and 21
#    specs that have never been published, which this script would have POSTed into existence as live paid
#    posts. Three of them had been REJECTED hours earlier - a retired $6.71/serving recipe, a held recipe
#    whose fresh/frozen contradiction was deliberately restored, and a spinach recipe rejected over
#    pricing. audit-db-agreement.ps1 skips specs with no index row, so nothing caught it.
#    -AllowCreate names the slugs permitted to be CREATED. Anything else that 404s is REFUSED and reported,
#    never POSTed. Republishing an existing post is unaffected: that is what the dirty set is for.
param([string[]]$Slugs, [switch]$All, [switch]$VerifyOnly, [switch]$Force, [switch]$Resume,
      [string[]]$AllowCreate, [switch]$AllowCreateAll)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path $here -Parent
$apiUrl = 'https://map-to-success.ghost.io'
$pubBase = 'https://www.thriftycrew.com'
. (Join-Path $PSScriptRoot '..\..\lib\ghost-lib.ps1')
. (Join-Path $PSScriptRoot '..\..\lib\ghost-drift-lib.ps1')   # Get-PublishedContentHash / Get-CanonicalBody for the pre-flight
# THE KEY COMES FROM Get-GhostKey, WHICH CHECKS $env:GHOST_ADMIN_KEY FIRST (2026-08-08). This line used to
# read meal-prep\.ghostkey directly, one line ABOVE the dot-source that provides the env-aware helper - so
# every other publisher in the daily chain (publish-deals-page, send-price-alerts, top5-weekly,
# rotate-free-dinners) could run from a CI runner and this one, the recipe card publisher, could not: the
# gitignored key file does not exist there, so it threw on line 21 before doing anything. The cloud backup
# has never completed a full run, and this is one of the reasons it would not have.
$adminKey = Get-GhostKey
. (Join-Path $PSScriptRoot '..\lib\render-tokens.ps1')  # Expand-SpecProse: {{stat}} tokens -> this spec's numbers
function New-GhostJWT { Get-GhostJWT -Key $adminKey }
function Get-ContentHash([string]$s){ $sha=[System.Security.Cryptography.SHA1]::Create(); return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) -replace '-','') }

if($All){ $Slugs = (Get-ChildItem (Join-Path $root 'db\built\*.body.html')).BaseName -replace '\.body$','' }
if(-not $Slugs){ throw 'no slugs' }

# published-content hashes (the change gate + resume journal in one file)
$hashFile = Join-Path $root 'db\published-hashes.json'
$pubHashes = @{}
if(Test-Path $hashFile){ try { $o=(Get-Content $hashFile -Raw | ConvertFrom-Json); foreach($p in $o.PSObject.Properties){ $pubHashes[$p.Name]=[string]$p.Value } } catch {} }

$ok=0; $skipped=0; $failed=@(); $refusedCreate=@()
foreach($slug in $Slugs){
  $spec = Get-Content (Join-Path $root "db\recipes\$slug.json") -Raw | ConvertFrom-Json
  # expand {{stat}} tokens BEFORE any field leaves this script: $desc feeds custom_excerpt, meta_description
  # AND the og/twitter pair, so an unexpanded token would ship to social verbatim. Expansion resolves from
  # this spec's own stat, and the change-gate hash is computed over the EXPANDED text - identical numbers
  # mean an identical hash, so the token migration itself republishes nothing.
  $spec = Expand-SpecProse $spec
  $spec = Move-SpecPriceToReleaseHydration $spec
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
    # THE CREATE GUARD. A 404 means this slug would be born here as a live paid post. That needs explicit
    # authority, because propagate hands this script every dirty spec and "dirty" includes recipes that were
    # rejected an hour ago. Refusing costs a re-run; creating costs a live page nobody approved.
    if(-not $existing -and -not $AllowCreateAll -and ($AllowCreate -notcontains $slug)){
      $refusedCreate += $slug
      Write-Output ("REFUSED CREATE  $slug  (no live post exists and it is not in -AllowCreate; pass it explicitly to create it)")
      continue
    }
    # CHANGE GATE: an existing post whose content bytes match the last verified publish is skipped
    # (visibility is deliberately NOT in the hash - the rotation owns it and its flip is not a content change).
    if($existing -and (-not $Force) -and ($pubHashes[$slug] -eq $contentHash)){ $skipped++; Write-Output ("UNCHANGED  $slug"); continue }

    # ---- PRE-FLIGHT: never overwrite a live body that no longer matches what we published (2026-08-08) ----
    # This PUT replaces the whole card. The change gate above compares LOCAL to the ledger; it says nothing
    # about whether LIVE still holds what the ledger records. So a card fixed by hand in Ghost admin, or one
    # left half-written by a PUT that failed after the body, gets silently overwritten by the next ordinary
    # republish - and the fix disappears with no trace. publish-tool-post.ps1 grew the same guard for the 16
    # tool pages; this is the same guard for the 542 recipe cards.
    # It costs one extra GET, and ONLY on slugs that are actually about to be written: the unchanged path
    # above has already returned, so a routine run that republishes nothing pays nothing.
    if($existing -and -not $Force -and $pubHashes.ContainsKey($slug) -and $pubHashes[$slug]){
      try {
        $jwt = New-GhostJWT
        $liveP = (Invoke-GhostApi -Uri "$apiUrl/ghost/api/admin/posts/$($existing.id)/?formats=lexical&fields=id,title,custom_excerpt,codeinjection_head,lexical" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}).posts[0]
        if($liveP -and $liveP.lexical){
          $liveLex = $liveP.lexical | ConvertFrom-Json
          $liveBody = ''
          foreach($c in $liveLex.root.children){ if($c.type -eq 'html' -and $c.html){ $liveBody += [string]$c.html } }
          if($liveBody){
            $liveHash = Get-PublishedContentHash -Body $liveBody -Head ([string]$liveP.codeinjection_head) -Name ([string]$liveP.title) -Desc ([string]$liveP.custom_excerpt)
            if($liveHash -ne $pubHashes[$slug]){
              # Ghost expands stored site-relative hrefs to absolute on read, so a card containing an internal
              # link can never hash equal however faithfully it was published. Fold that one transformation
              # before calling it drift - measured 4 of 542 on the first sweep, every one exactly the host.
              $lastBody = [IO.File]::ReadAllText((Join-Path $root "db\built\$slug.body.html"), [Text.Encoding]::UTF8)
              if((Get-CanonicalBody $lastBody) -ne (Get-CanonicalBody $liveBody)){
                $failed += $slug
                Write-Output ("REFUSING  $slug  - the LIVE card no longer matches what we last published, so this PUT would DELETE whatever changed it.")
                Write-Output ("          live body {0} bytes vs built {1}. Look first (grocery\audit-ghost-drift.ps1 -Recipes), then re-run with -Force if you mean to overwrite it." -f $liveBody.Length, $lastBody.Length)
                continue
              }
            }
          }
        }
      } catch { Write-Output ("  pre-flight check could not read $slug live ($($_.Exception.Message)) - publishing anyway") }
    }

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
      # og_/twitter_ ARE SEPARATE STORED FIELDS, not fallbacks (2026-08-07). Ghost only falls back to
      # custom_excerpt when these are empty; once a post is created with them set they are frozen, and this
      # publisher rewrote meta_description on every run while leaving them untouched. Measured on
      # slow-cooker-butter-chicken-rice-bowls: meta_description and the JSON-LD both said "610 calories ...
      # $3.58 each" while og:description and twitter:description still said "592 cal ... about $1.90 a bowl" -
      # the numbers every social share and some search snippets actually show. Same $desc, so all four
      # surfaces now move together or none do.
      og_description=$desc
      twitter_description=$desc
      og_title=$spec.name
      twitter_title=$spec.name
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
# Refusals are LOUD. A silently-skipped create is how 21 unaudited specs nearly became live paid posts.
if($refusedCreate){
  Write-Output ("REFUSED CREATE (" + $refusedCreate.Count + " slug(s) had no live post and no -AllowCreate authority): " + ($refusedCreate -join ', '))
  Write-Output ("  These were NOT published. If they should exist, pass them in -AllowCreate deliberately.")
}
