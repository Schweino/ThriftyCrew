<#
  build-series-page.ps1  -  Builds/updates the "/the-52-week-program/" page: a dedicated
  home for the closed 52-week series (all 52 weeks in order + a "Start with Week 1" CTA).
  The 52 weeks are fixed, so this only needs running once (or to regenerate). Idempotent.
#>
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
$jwt = New-GhostJWT $adminKey
$posts = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/?limit=all&filter=tag:financial-lessons&fields=slug,title&formats=" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}).posts

# collect the numbered weeks, in order
$weeks = @()
foreach ($p in $posts) { if ($p.title -match 'Week\s+(\d+)') { $weeks += [pscustomobject]@{ n=[int]$Matches[1]; slug=$p.slug; title=$p.title } } }
$weeks = $weeks | Sort-Object n
Write-Host ("Found {0} numbered weeks." -f $weeks.Count)

$lis = ""
foreach ($w in $weeks) {
  $disp = ($w.title -replace '\s*\(Free!\)\s*','')
  $free = ""
  if ($w.title -match '\(Free!\)') { $free = ' <span style="color:#8a6d1f;font-weight:700;font-size:.8em;">&middot; free</span>' }
  $lis += "<li style=""margin-bottom:.55rem;""><a href=""/$($w.slug)/"">$disp</a>$free</li>"
}

$start = ($weeks | Where-Object { $_.n -eq 1 } | Select-Object -First 1)
$startSlug = if ($start) { $start.slug } else { $weeks[0].slug }
$dollar = [char]0x24

$html = @"
<div style="max-width:720px;margin:0 auto;">
<div class="mts-tagintro"><div class="mts-tagintro-inner"><p><strong>A full year of money skills &mdash; one idea at a time.</strong> The 52-Week Money Program is the original Thrifty Crew series: 52 short, practical lessons that build on each other. Start at Week 1 and go in order, or jump to whatever you need most. Use them for your own life, or to teach a young person in yours.</p></div></div>
<div class="mts-cta" style="text-align:center;border:none;background:none;padding:.4rem 0 1.6rem;"><a class="mts-btn mts-btn-gold" href="/$startSlug/">Start with Week 1 &rarr;</a></div>
<h2 style="font-family:Georgia,'Times New Roman',serif;color:#16263F;">All 52 weeks, in order</h2>
<ol style="line-height:1.6;font-size:1.65rem;padding-left:1.6rem;">$lis</ol>
<div class="mts-cta"><p class="mts-cta-lead">Unlock all 52 weeks for ${dollar}10 a year.</p><p>The whole program &mdash; plus every budget recipe &mdash; for about ${dollar}0.83 a month. It pays for itself the first grocery run. Cancel anytime.</p><a class="mts-btn mts-btn-gold" href="#/portal/signup">Get ahead now &rarr;</a></div>
</div>
"@

$metaTitle = "The 52-Week Money Program | Thrifty Crew"
$metaDesc  = "A full year of short, practical money lessons. Start at Week 1 and build real financial skills one week at a time."

$jwt = New-GhostJWT $adminKey
$existing = $null
try { $existing = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/pages/slug/the-52-week-program/?fields=id,updated_at" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}).pages[0] } catch {}
$lexObj = @{ root = [ordered]@{ children=@([ordered]@{ type='html'; version=1; html=[string]$html }); direction=$null; format=''; indent=0; type='root'; version=1 } }
$lex = ConvertTo-Json $lexObj -Depth 12 -Compress
$pageObj = [ordered]@{ title='The 52-Week Money Program'; slug='the-52-week-program'; lexical=$lex; status='published'; meta_title=$metaTitle; meta_description=$metaDesc; og_title=$metaTitle; og_description=$metaDesc; twitter_title=$metaTitle; twitter_description=$metaDesc }
if ($existing) { $pageObj.updated_at=$existing.updated_at; $method='Put'; $uri="$apiUrl/ghost/api/admin/pages/$($existing.id)/" }
else { $method='Post'; $uri="$apiUrl/ghost/api/admin/pages/" }
$payload = @{ pages=@($pageObj) }
$bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $payload -Depth 16))
$jwt2 = New-GhostJWT $adminKey
Invoke-RestMethod -Uri $uri -Method $method -Headers @{Authorization="Ghost $jwt2";'Accept-Version'='v5.0'} -ContentType 'application/json' -Body $bytes | Out-Null
$verb = if ($existing) { "Updated" } else { "Created" }
Write-Host ("{0}: {1}/the-52-week-program/  ({2} weeks listed, Start=/{3}/)" -f $verb, $apiUrl, $weeks.Count, $startSlug) -ForegroundColor Green
