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
foreach($kind in @('posts','pages')){
  try {
    $r=Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/$kind/slug/omaha-price-tracker/?formats=html" -Headers @{Authorization=("Ghost "+(Jwt)); 'Accept-Version'='v5.0'}
    $o=$r.$kind[0]
    Write-Output ("FOUND in "+$kind+": id="+$o.id+" status="+$o.status+" visibility="+$o.visibility+" updated_at="+$o.updated_at)
    Write-Output ("  title: "+$o.title)
    Write-Output ("  tags: "+ (($o.tags | ForEach-Object { $_.name }) -join ', '))
    Write-Output ("  excerpt: "+$o.custom_excerpt)
    $html=[string]$o.html
    Write-Output ("  body has 'six': "+ ([regex]::IsMatch($html,'\bsix\b')))
    Write-Output ("  body has Fareway: "+ $html.Contains('Fareway'))
  } catch { Write-Output ("not a $kind (or error): "+$_.Exception.Message) }
}