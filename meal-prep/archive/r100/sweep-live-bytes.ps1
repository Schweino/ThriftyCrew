# sweep-live-bytes.ps1 - Byte-sweeps every published r100 card: Ghost admin html vs built\<slug>.body.html.
# Normalization (PIPELINE ordering lesson): strip <!--kg-card-begin: html--> / <!--kg-card-end: html-->
# wrappers and CRLF->LF, then exact string compare. Any republish must run AFTER the last card rebuild,
# then this sweep confirms live == built for the full set.
param([string[]]$Slugs)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$apiUrl = 'https://map-to-success.ghost.io'
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
function Normalize([string]$s){
  $s = $s -replace '<!--kg-card-begin: html-->\s*',''
  $s = $s -replace '\s*<!--kg-card-end: html-->',''
  $s = $s.Replace("`r`n","`n")
  $s.Trim()
}

if(-not $Slugs){ $Slugs = Get-Content (Join-Path $here 'specs-ready.txt') | Where-Object { $_ } }
$ok=0; $bad=@()
foreach($slug in $Slugs){
  $built = Normalize ([IO.File]::ReadAllText((Join-Path $here "built\$slug.body.html"), [Text.Encoding]::UTF8))
  $jwt = New-GhostJWT $adminKey
  try {
    $post = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$slug/?formats=html&fields=html" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -TimeoutSec 30).posts[0]
  } catch { $bad += $slug; Write-Output ("FETCH FAIL  $slug :: " + $_.Exception.Message); continue }
  $live = Normalize ([string]$post.html)
  if($live -eq $built){ $ok++ }
  else {
    $bad += $slug
    $n=[Math]::Min($live.Length,$built.Length); $i=0
    while($i -lt $n -and $live[$i] -eq $built[$i]){ $i++ }
    Write-Output ("MISMATCH  $slug  (live $($live.Length)B built $($built.Length)B, first diff @ char $i)")
    Write-Output ("   live : ..." + $live.Substring([Math]::Max(0,$i-40),[Math]::Min(80,$live.Length-[Math]::Max(0,$i-40))))
    Write-Output ("   built: ..." + $built.Substring([Math]::Max(0,$i-40),[Math]::Min(80,$built.Length-[Math]::Max(0,$i-40))))
  }
}
Write-Output ("byte-identical: $ok / $($Slugs.Count)")
if($bad){ Write-Output ("BAD: " + ($bad -join ', ')) } else { Write-Output "SWEEP CLEAN" }
