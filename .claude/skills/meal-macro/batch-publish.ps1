<#
  batch-publish.ps1  -  Publishes every item in all mf-*.json manifests in a folder to Ghost.
  Each manifest item: {slug,title,excerpt,metaTitle,metaDesc,visibility,htmlfile}.
  Tag is derived from the manifest filename: mf-gloss-* -> Glossary, mf-hack-* -> Money Hacks,
  otherwise Resources. Paid/members items get the paywall JSON-LD. Upserts by slug (safe to re-run).
#>
param([Parameter(Mandatory=$true)][string]$GenDir)
$ErrorActionPreference='Stop'
. "C:\Codex\ThriftyCrew\.claude\skills\lesson\ghost-config.ps1"
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
$ok=0;$fail=0
foreach($mf in (Get-ChildItem "$GenDir\mf-*.json")){
  $tag = if($mf.Name -match 'gloss'){'Glossary'} elseif($mf.Name -match 'hack'){'Money Hacks'} else {'Resources'}
  $items = Get-Content $mf.FullName -Raw | ConvertFrom-Json
  foreach($it in $items){
    try {
      $htmlPath = Join-Path $GenDir $it.htmlfile
      if(-not (Test-Path $htmlPath)){ Write-Output "MISSING $($it.slug)"; $fail++; continue }
      $html=[IO.File]::ReadAllText($htmlPath,[Text.Encoding]::UTF8)
      if([string]::IsNullOrWhiteSpace($html)){ Write-Output "EMPTY $($it.slug)"; $fail++; continue }
      $vis = if($it.visibility){[string]$it.visibility}else{'public'}
      $postUrl="$apiUrl/$($it.slug)/"
      $cih=''
      if($vis -ne 'public'){
        $pw=[ordered]@{'@context'='https://schema.org';'@type'='Article';isAccessibleForFree=$false;hasPart=[ordered]@{'@type'='WebPageElement';isAccessibleForFree=$false;cssSelector='.gh-content'};mainEntityOfPage=$postUrl;headline=$it.title}
        $cih='<script type="application/ld+json">'+(ConvertTo-Json $pw -Compress -Depth 6)+'</script>'
      }
      $jwt=New-GhostJWT $adminKey
      $existing=$null
      try{ $existing=(Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$($it.slug)/?fields=id,updated_at" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}).posts[0] }catch{}
      $lexObj=@{root=[ordered]@{children=@([ordered]@{type='html';version=1;html=[string]$html});direction=$null;format='';indent=0;type='root';version=1}}
      $lex=ConvertTo-Json $lexObj -Depth 12 -Compress
      $postObj=[ordered]@{title=$it.title;slug=$it.slug;lexical=$lex;status='published';visibility=$vis;custom_excerpt=$it.excerpt;tags=@(@{name=$tag});meta_title=$it.metaTitle;meta_description=$it.metaDesc;og_title=$it.metaTitle;og_description=$it.metaDesc;twitter_title=$it.metaTitle;twitter_description=$it.metaDesc;codeinjection_head=$cih}
      if($existing){ $postObj.updated_at=$existing.updated_at;$method='Put';$uri="$apiUrl/ghost/api/admin/posts/$($existing.id)/" } else { $method='Post';$uri="$apiUrl/ghost/api/admin/posts/" }
      $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json @{posts=@($postObj)} -Depth 14))
      $jwt=New-GhostJWT $adminKey
      $r=Invoke-RestMethod -Uri $uri -Method $method -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -ContentType 'application/json' -Body $bytes -TimeoutSec 30
      $ok++; Write-Output ("OK   [$tag] $($it.slug)")
    } catch { $fail++; Write-Output ("FAIL $($it.slug) :: "+$_.Exception.Message) }
  }
}
Write-Output "BATCH DONE ok=$ok fail=$fail"
if($ok -gt 0){
  $doneDir = Join-Path $GenDir 'done'
  if(-not (Test-Path $doneDir)){ New-Item -ItemType Directory -Path $doneDir | Out-Null }
  Get-ChildItem -Path $GenDir -Filter *.html -File -ErrorAction SilentlyContinue | Move-Item -Destination $doneDir -Force
  Get-ChildItem -Path $GenDir -Filter 'mf-*.json' -File -ErrorAction SilentlyContinue | Move-Item -Destination $doneDir -Force
  Write-Output "ARCHIVED published files to done/ (gen is now clean for the next wave)"
}
