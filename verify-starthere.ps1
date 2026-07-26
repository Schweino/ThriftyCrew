$ErrorActionPreference='Stop'
$adminKey=(Get-Content 'C:\Codex\income\meal-prep\.ghostkey' -Raw).Trim()
$apiUrl='https://map-to-success.ghost.io'
$p=$adminKey -split ':'; $id=$p[0]; $secretHex=$p[1]
$sb=New-Object byte[] ($secretHex.Length/2); for($i=0;$i -lt $sb.Length;$i++){ $sb[$i]=[Convert]::ToByte($secretHex.Substring($i*2,2),16) }
$now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$h='{"alg":"HS256","typ":"JWT","kid":"'+$id+'"}'; $pl='{"iat":'+$now+',"exp":'+($now+300)+',"aud":"/admin/"}'
$b64={param($b)[Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_')}
$si=(& $b64 ([Text.Encoding]::UTF8.GetBytes($h)))+'.'+(& $b64 ([Text.Encoding]::UTF8.GetBytes($pl)))
$hm=New-Object System.Security.Cryptography.HMACSHA256 (,$sb); $jwt=$si+'.'+(& $b64 ($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes($si))))
$hdr=@{ Authorization="Ghost $jwt"; 'Accept-Version'='v5.0' }
$post=(Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/start-here/?formats=html" -Headers $hdr -TimeoutSec 30).posts[0]
$html=[string]$post.html
Write-Output ("stored html length: "+$html.Length)
foreach($needle in @('Omaha grocery price board','More than 100 real','built right into the site','52 financial lessons','Google Sheets','private Google Sheets','See this week','omaha-grocery-prices')){
  Write-Output ("contains ["+$needle+"]: "+ $html.Contains($needle))
}
$em = ([regex]::Matches($html,[char]0x2014)).Count
Write-Output ("em-dash count: "+$em)
$h2 = ([regex]::Matches($html,'<h2')).Count; $h3=([regex]::Matches($html,'<h3').Count)
Write-Output ("h2 count: "+$h2+"  h3 count: "+$h3)