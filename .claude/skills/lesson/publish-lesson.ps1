<#
  publish-lesson.ps1  -  Publishes ONE Thrifty Crew financial lesson to Ghost,
  following every established convention so it is indistinguishable in fit from
  the existing lessons. The site's global Code Injection auto-adds the financial
  disclaimer, "Keep going" links, breadcrumb + FAQ JSON-LD, 620px reading measure,
  and active-nav highlight to ANY post tagged financial-lessons -- so this script
  only sets the fields; the styling/SEO "fit" then happens automatically.

  New lessons use a NORMAL title (no "Week N") and publish at the current time
  (newest in the archive). Example:
    powershell -ExecutionPolicy Bypass -File publish-lesson.ps1 `
      -Title "How to Read a Pay Stub" -Slug "how-to-read-a-pay-stub" `
      -HtmlFile "C:\...\lesson-body.html" `
      -Excerpt "One-line hook that works solo or when teaching a young person." `
      -MetaTitle "How to Read a Pay Stub | Thrifty Crew" `
      -MetaDesc "Benefit-led ~150-char description, plain and keyword-aware."
  Switches: -Draft (publish as draft for review) ; -Visibility public (a free lesson).
  LEGACY: -WeekNumber N is only for editing an existing Week 1-52 lesson (it dates the
  post into that week's archive slot). Do NOT use it for new standalone lessons.
  It NEVER emails members (no newsletter param is sent).
#>
param(
  [Parameter(Mandatory=$true)][string]$Title,
  [Parameter(Mandatory=$true)][string]$Slug,
  [Parameter(Mandatory=$true)][string]$HtmlFile,
  [Parameter(Mandatory=$true)][string]$Excerpt,
  [Parameter(Mandatory=$true)][string]$MetaTitle,
  [Parameter(Mandatory=$true)][string]$MetaDesc,
  [int]$WeekNumber = 0,
  [ValidateSet('paid','public','members')][string]$Visibility = 'paid',
  [switch]$Draft
)
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\ghost-config.ps1"   # -> $adminKey, $apiUrl

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

if (-not (Test-Path $HtmlFile)) { throw "HtmlFile not found: $HtmlFile" }
$html = [IO.File]::ReadAllText($HtmlFile, [Text.Encoding]::UTF8)
if ([string]::IsNullOrWhiteSpace($html)) { throw "HtmlFile is empty: $HtmlFile" }

# --- financial-lessons tag (reference by id so we never create a duplicate) ---
$jwt = New-GhostJWT $adminKey
$tag = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/tags/slug/financial-lessons/?fields=id,name" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}).tags[0]
if (-not $tag) { throw "Could not find the 'financial-lessons' tag." }

# --- existing lessons -> compute the correct published_at for archive ordering ---
# Archive is newest-first and lessons are dated so Week 1 = newest (top) ... higher weeks = older (down).
$jwt = New-GhostJWT $adminKey
$existingLessons = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/?limit=all&filter=tag:financial-lessons&fields=title,published_at&formats=" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}).posts
$weekDates = @{}
foreach ($p in $existingLessons) { if ($p.title -match 'Week\s+(\d+)') { $weekDates[[int]$Matches[1]] = [datetime]$p.published_at } }

$publishedAt = $null
if ($WeekNumber -gt 0 -and $weekDates.Count -gt 0) {
  $prev = @($weekDates.Keys | Where-Object { $_ -lt $WeekNumber } | Sort-Object -Descending)  # weeks above (newer)
  $next = @($weekDates.Keys | Where-Object { $_ -gt $WeekNumber } | Sort-Object)               # weeks below (older)
  if ($prev.Count -gt 0 -and $next.Count -gt 0) {
    $dPrev = $weekDates[$prev[0]]; $dNext = $weekDates[$next[0]]
    $publishedAt = $dNext.AddSeconds( ($dPrev - $dNext).TotalSeconds / 2 )
  } elseif ($prev.Count -gt 0) { $publishedAt = $weekDates[$prev[0]].AddDays(-1) }
  elseif ($next.Count -gt 0)   { $publishedAt = $weekDates[$next[0]].AddDays(1) }
}

# --- paywall structured data for gated lessons (matches the other gated posts) ---
$postUrl = "$apiUrl/$Slug/"
$cih = ''
if ($Visibility -ne 'public') {
  $pw = [ordered]@{ '@context'='https://schema.org'; '@type'='Article'; isAccessibleForFree=$false;
    hasPart=[ordered]@{ '@type'='WebPageElement'; isAccessibleForFree=$false; cssSelector='.gh-content' };
    mainEntityOfPage=$postUrl; headline=$Title }
  $cih = '<script type="application/ld+json">' + (ConvertTo-Json $pw -Compress -Depth 6) + '</script>'
}

$status = if ($Draft) { 'draft' } else { 'published' }

# --- upsert by slug (so re-running edits the same lesson instead of duplicating) ---
$jwt = New-GhostJWT $adminKey
$existing = $null
try { $existing = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$Slug/?fields=id,updated_at" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}).posts[0] } catch {}

$postObj = [ordered]@{
  title=$Title; slug=$Slug; html=$html; status=$status; visibility=$Visibility;
  custom_excerpt=$Excerpt; tags=@(@{ id=$tag.id });
  meta_title=$MetaTitle; meta_description=$MetaDesc;
  og_title=$MetaTitle; og_description=$MetaDesc; twitter_title=$MetaTitle; twitter_description=$MetaDesc;
  codeinjection_head=$cih
}
# only set the ordering date on CREATE (never move an existing lesson)
if (-not $existing -and $publishedAt) { $postObj.published_at = $publishedAt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.000Z") }

if ($existing) { $postObj.updated_at=$existing.updated_at; $method='Put'; $uri="$apiUrl/ghost/api/admin/posts/$($existing.id)/?source=html" }
else { $method='Post'; $uri="$apiUrl/ghost/api/admin/posts/?source=html" }

$payload = @{ posts = @($postObj) }
$bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $payload -Depth 12))
$jwt = New-GhostJWT $adminKey
$r = Invoke-RestMethod -Uri $uri -Method $method -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -ContentType 'application/json' -Body $bytes
$saved = $r.posts[0]
$verb = if ($existing) { "UPDATED" } else { "CREATED" }
Write-Host ("{0}: {1}" -f $verb, $postUrl) -ForegroundColor Green
Write-Host ("  status={0}  visibility={1}  tag={2}  paywallSchema={3}  weekOrderDate={4}" -f `
  $saved.status, $saved.visibility, $tag.name, [bool]$cih, $(if($postObj.published_at){$postObj.published_at}else{'(kept existing)'}))
