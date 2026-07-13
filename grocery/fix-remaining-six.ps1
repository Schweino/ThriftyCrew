$ErrorActionPreference='Stop'
$here='C:\Codex\income\grocery'
$adminKey = if (Test-Path (Join-Path $here '.ghostkey')) { (Get-Content (Join-Path $here '.ghostkey') -Raw).Trim() } else { (Get-Content 'C:\Codex\income\meal-prep\.ghostkey' -Raw).Trim() }
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
$fields=@('custom_excerpt','meta_description','og_description','twitter_description')
foreach($slug in @('whole-chicken-price-omaha','omaha-price-tracker')){
  $r=Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$slug/?fields=id,updated_at,$([string]::Join(',',$fields))" -Headers @{Authorization=("Ghost "+(Jwt)); 'Accept-Version'='v5.0'}
  $o=$r.posts[0]
  $upd=[ordered]@{ updated_at=$o.updated_at }
  $changed=@()
  foreach($f in $fields){
    $val=[string]$o.$f
    if ($val -and ($val -match '(?i)\bsix\b')) {
      $nv = [regex]::Replace($val,'(?i)\bsix\b','seven')
      $upd[$f]=$nv; $changed+=$f
    }
  }
  if ($changed.Count -eq 0) { Write-Output ("$slug : nothing to change"); continue }
  $payload=@{ posts=@($upd) }
  $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $payload -Depth 8))
  $pr=Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/$($o.id)/" -Method Put -Headers @{Authorization=("Ghost "+(Jwt)); 'Accept-Version'='v5.0'} -ContentType 'application/json' -Body $bytes
  Write-Output ("$slug : updated fields ["+([string]::Join(', ',$changed))+"]  -> status "+$pr.posts[0].status)
}