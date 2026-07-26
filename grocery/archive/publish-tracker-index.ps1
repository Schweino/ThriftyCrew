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
$frag=[IO.File]::ReadAllText((Join-Path $here 'out\trend\index.html'), [Text.Encoding]::UTF8)
if ([regex]::IsMatch($frag,'\bsix\b')) { throw 'Refusing to publish: index fragment still contains the word "six".' }
if (-not $frag.Contains('Fareway')) { throw 'Refusing to publish: index fragment missing Fareway.' }
$lexObj = @{ root = [ordered]@{ children = @([ordered]@{ type='html'; version=1; html=$frag }); direction=$null; format=''; indent=0; type='root'; version=1 } }
$lex = ConvertTo-Json $lexObj -Depth 12 -Compress
# fresh updated_at
$cur=(Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/omaha-price-tracker/?fields=id,updated_at" -Headers @{Authorization=("Ghost "+(Jwt)); 'Accept-Version'='v5.0'}).posts[0]
$postObj=[ordered]@{ lexical=$lex; updated_at=$cur.updated_at }
$payload=@{ posts=@($postObj) }
$bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $payload -Depth 14))
$r=Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/$($cur.id)/" -Method Put -Headers @{Authorization=("Ghost "+(Jwt)); 'Accept-Version'='v5.0'} -ContentType 'application/json' -Body $bytes -TimeoutSec 30
$saved=$r.posts[0]
Write-Output ("UPDATED /omaha-price-tracker/  status="+$saved.status+" visibility="+$saved.visibility+" updated_at="+$saved.updated_at)