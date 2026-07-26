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
$s=Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/settings/" -Headers $hdr -TimeoutSec 30
$foot=($s.settings | Where-Object { $_.key -eq 'codeinjection_foot' }).value
Write-Output ("foot length: "+([string]$foot).Length)
[IO.File]::WriteAllText('C:\Codex\income\site-backups\codeinjection-foot-BEFORE-homepage-copy-2026-07-13.html', [string]$foot, (New-Object Text.UTF8Encoding($false)))
$targets=@(
 'We price-check six grocery stores every morning',
 'Every morning we check 90+ staples at six stores in Omaha',
 'Budget, savings, debt payoff, and &ldquo;where do you stand?&rdquo;'
)
foreach($t in $targets){ Write-Output ("present ["+$t.Substring(0,[Math]::Min(45,$t.Length))+"...]: "+ ([string]$foot).Contains($t)) }
Write-Output ("has interstitial: "+ ([string]$foot).Contains('tc-join-interstitial'))
Write-Output ("count 'six': "+ ([regex]::Matches([string]$foot,'six')).Count)
Write-Output "backed up live foot -> site-backups\codeinjection-foot-BEFORE-homepage-copy-2026-07-13.html"