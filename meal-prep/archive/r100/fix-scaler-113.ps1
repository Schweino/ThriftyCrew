# fix-scaler-113.ps1 - Patches the live scaler payloads of the pre-r100 cards flagged by
# audit-scaler-113.ps1 (same unit-reconciliation bug as PIPELINE FIX 2: payload gpu calibrated to an old
# map era while the widget prices against today's feed/board units). Surgery is TARGETED: only the gpu
# number of each flagged (item,bid) entry inside the smp-sc-data JSON changes; every other byte of the
# card is preserved. PUT back as a single lexical html card (never ?source=html), then refetch-verified.
# Usage: fix-scaler-113.ps1 [-DryRun]
param([switch]$DryRun)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$apiUrl='https://map-to-success.ghost.io'
$adminKey=(Get-Content (Join-Path $here '..\.ghostkey') -Raw).Trim()
$backupDir = Join-Path $here 'scaler-113-backups'
if(-not (Test-Path $backupDir)){ New-Item -ItemType Directory $backupDir | Out-Null }

function New-GhostJWT {
  $p=$script:adminKey -split ':'; $sb=New-Object byte[] ($p[1].Length/2)
  for($i=0;$i -lt $sb.Length;$i++){ $sb[$i]=[Convert]::ToByte($p[1].Substring($i*2,2),16) }
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $h='{"alg":"HS256","typ":"JWT","kid":"'+$p[0]+'"}'; $pl='{"iat":'+$now+',"exp":'+($now+300)+',"aud":"/admin/"}'
  $b64={param($b)[Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_')}
  $si=(& $b64 ([Text.Encoding]::UTF8.GetBytes($h)))+'.'+(& $b64 ([Text.Encoding]::UTF8.GetBytes($pl)))
  $hm=New-Object System.Security.Cryptography.HMACSHA256 (,$sb)
  return $si+'.'+(& $b64 ($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes($si))))
}
function GpuStr([double]$v){ $v.ToString('0.000') }

# parse the audit report: "slug :: item [bid] live gpu=G expected=E (...)"
$fixes=@{}
foreach($line in (Get-Content (Join-Path $here 'audit-113-bugs.txt') | Where-Object { $_ })){
  $m=[regex]::Match($line,'^(\S+) :: (.+?) \[(\S+)\] live gpu=([0-9.]+) expected=([0-9.]+) ')
  if(-not $m.Success){ throw ('unparseable audit line: ' + $line) }
  $slug=$m.Groups[1].Value
  if(-not $fixes.ContainsKey($slug)){ $fixes[$slug]=@() }
  $fixes[$slug] += @{ item=$m.Groups[2].Value; bid=$m.Groups[3].Value; expected=[double]$m.Groups[5].Value }
}
Write-Output ("cards to fix: $($fixes.Count); entries: " + (($fixes.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum))

$ok=0; $failed=@()
foreach($slug in ($fixes.Keys | Sort-Object)){
  $jwt=New-GhostJWT
  $hdr=@{ Authorization="Ghost $jwt"; 'Accept-Version'='v5.0' }
  $post=$null
  try { $post=(Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$slug/?formats=html&fields=id,html,updated_at" -Headers $hdr -TimeoutSec 30).posts[0] } catch {}
  if(-not $post){ $failed += ($slug + ' :: post fetch failed'); continue }
  $html=[string]$post.html
  $html=$html -replace '<!--kg-card-(begin|end): html-->',''

  $mPay=[regex]::Match($html,'(class="smp-sc-data">\s*)(\{.*?\})(\s*</script>)','Singleline')
  if(-not $mPay.Success){ $failed += ($slug + ' :: no scaler payload'); continue }
  $payload=$mPay.Groups[2].Value
  $newPayload=$payload; $bad=$null
  foreach($f in $fixes[$slug]){
    $pat = '("item":"' + [regex]::Escape($f.item) + '","grams":\d+,"buy":"[^"]*","bid":"' + [regex]::Escape($f.bid) + '","gpu":)([0-9.]+)'
    $mm=[regex]::Matches($newPayload,$pat)
    if($mm.Count -ne 1){ $bad=("entry match count $($mm.Count) for $($f.item) [$($f.bid)]"); break }
    $newPayload = [regex]::Replace($newPayload,$pat,('${1}' + (GpuStr $f.expected)),1)
  }
  if($bad){ $failed += ($slug + ' :: ' + $bad); continue }
  # structural sanity: new payload must still parse and carry every fix
  $chkObj = $null
  try { $chkObj = $newPayload | ConvertFrom-Json } catch { $failed += ($slug + ' :: patched payload no longer parses'); continue }
  $verifyBad=$null
  foreach($f in $fixes[$slug]){
    $e = $chkObj.ing | Where-Object { $_.item -eq $f.item -and $_.bid -eq $f.bid }
    if(-not $e -or [Math]::Abs([double]$e.gpu - $f.expected) -gt 0.001){ $verifyBad=$f.item; break }
  }
  if($verifyBad){ $failed += ($slug + ' :: patched value did not take for ' + $verifyBad); continue }
  if($DryRun){ Write-Output ("DRY $slug : $($fixes[$slug].Count) entries"); $ok++; continue }

  # backup the pre-fix html, then PUT
  $html | Set-Content (Join-Path $backupDir ($slug + '.pre-fix.html')) -Encoding UTF8
  $newHtml = $html.Replace($payload,$newPayload)
  $lexObj=@{root=[ordered]@{children=@([ordered]@{type='html';version=1;html=[string]$newHtml});direction=$null;format='';indent=0;type='root';version=1}}
  $lex=ConvertTo-Json $lexObj -Depth 12 -Compress
  $bodyJson=@{ posts=@(@{ lexical=$lex; updated_at=$post.updated_at }) } | ConvertTo-Json -Depth 14
  $jwt=New-GhostJWT
  try {
    Invoke-RestMethod -Method PUT -Uri "$apiUrl/ghost/api/admin/posts/$($post.id)/" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0';'Content-Type'='application/json'} -Body ([Text.Encoding]::UTF8.GetBytes($bodyJson)) -TimeoutSec 60 | Out-Null
  } catch { $failed += ($slug + ' :: PUT failed ' + $_.Exception.Message); continue }

  # refetch-verify: payload parses and every fixed gpu is live
  Start-Sleep -Milliseconds 300
  $jwt=New-GhostJWT
  $chk=(Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$slug/?formats=html&fields=html" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -TimeoutSec 30).posts[0].html
  $mChk=[regex]::Match([string]$chk,'class="smp-sc-data">\s*(\{.*?\})\s*</script>','Singleline')
  $good=$false
  if($mChk.Success){
    try {
      $liveObj=$mChk.Groups[1].Value | ConvertFrom-Json
      $good=$true
      foreach($f in $fixes[$slug]){
        $e = $liveObj.ing | Where-Object { $_.item -eq $f.item -and $_.bid -eq $f.bid }
        if(-not $e -or [Math]::Abs([double]$e.gpu - $f.expected) -gt 0.001){ $good=$false; break }
      }
    } catch { $good=$false }
  }
  if($good){ $ok++; Write-Output ("OK  $slug : $($fixes[$slug].Count) entries") }
  else { $failed += ($slug + ' :: live verify failed') }
}
Write-Output ("fixed OK: $ok / $($fixes.Count)")
if($failed){ Write-Output 'FAILED:'; $failed | ForEach-Object { "  $_" } }
