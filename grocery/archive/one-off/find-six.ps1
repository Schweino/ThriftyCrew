$ErrorActionPreference='Stop'
$here='C:\Codex\ThriftyCrew\grocery'
$adminKey = if (Test-Path (Join-Path $here '.ghostkey')) { (Get-Content (Join-Path $here '.ghostkey') -Raw).Trim() } else { (Get-Content 'C:\Codex\ThriftyCrew\meal-prep\.ghostkey' -Raw).Trim() }
$apiUrl='https://map-to-success.ghost.io'
$p=$adminKey -split ':'; $id=$p[0]; $secretHex=$p[1]
$sb=New-Object byte[] ($secretHex.Length/2); for($i=0;$i -lt $sb.Length;$i++){ $sb[$i]=[Convert]::ToByte($secretHex.Substring($i*2,2),16) }
function Jwt {
 $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
 $h='{"alg":"HS256","typ":"JWT","kid":"'+$id+'"}'; $pl='{"iat":'+$now+',"exp":'+($now+300)+',"aud":"/admin/"}'
 $b64={param($b)[Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_')}
 $si=(& $b64 ([Text.Encoding]::UTF8.GetBytes($h)))+'.'+(& $b64 ([Text.Encoding]::UTF8.GetBytes($pl)))
 $hm=New-Object System.Security.Cryptography.HMACSHA256 (,$sb); $si+'.'+(& $b64 ($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes($si))))
}
# all Price Tracker posts - find any with "six" in excerpt or meta
$posts=@()
$page=1
do {
  $r=Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/?filter=tag:hash-price-tracker,tag:price-tracker&limit=50&page=$page&fields=id,slug,custom_excerpt,meta_description" -Headers @{Authorization=("Ghost "+(Jwt)); 'Accept-Version'='v5.0'}
  $posts += $r.posts
  $next=$r.meta.pagination.next
  $page++
} while ($next)
Write-Output ("Price Tracker posts: "+$posts.Count)
$bad = $posts | Where-Object { ([string]$_.custom_excerpt -match '\bsix\b') -or ([string]$_.meta_description -match '\bsix\b') }
Write-Output ("posts still containing 'six': "+ @($bad).Count)
foreach($b in $bad){ Write-Output ("  "+$b.slug+" | excerpt='"+$b.custom_excerpt+"' | meta='"+$b.meta_description+"'") }
# tracker meta specifically
$tr=$posts | Where-Object { $_.slug -eq 'omaha-price-tracker' }
if($tr){ Write-Output ("TRACKER meta_description: "+$tr.meta_description) }