$ErrorActionPreference = "Stop"
. "$PSScriptRoot\ghost-config.ps1"
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
function JStr($s){ $sb=New-Object System.Text.StringBuilder; [void]$sb.Append('"'); foreach($ch in $s.ToCharArray()){ switch($ch){ '"'{[void]$sb.Append('\"');break} '\'{[void]$sb.Append('\\');break} "`n"{[void]$sb.Append('\n');break} "`r"{[void]$sb.Append('\r');break} "`t"{[void]$sb.Append('\t');break} default{ if([int]$ch -lt 0x20){[void]$sb.AppendFormat('\u{0:x4}',[int]$ch)}else{[void]$sb.Append($ch)} } } }; [void]$sb.Append('"'); return $sb.ToString() }

$jwt = New-GhostJWT $adminKey
$H = @{ Authorization="Ghost $jwt"; 'Accept-Version'='v5.0' }
$p = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/pages/slug/membership/?formats=lexical" -Headers $H).pages[0]
$lex = $p.lexical
$old = 'Budget templates &amp; trackers'
$new = 'Budget tracker + savings, compound &amp; debt calculators'
$count = ([regex]::Matches($lex, [regex]::Escape($old))).Count
Write-Host "Occurrences of old label: $count" -ForegroundColor DarkGray
if ($count -eq 0) { Write-Host "Nothing to replace (already updated?)" -ForegroundColor Yellow; exit }
$newLex = $lex.Replace($old, $new)
# validate JSON round-trips
$null = $newLex | ConvertFrom-Json
Write-Host "JSON validates OK." -ForegroundColor DarkGray

$body = '{"pages":[{"lexical":' + (JStr $newLex) + ',"updated_at":' + (JStr $p.updated_at) + '}]}'
$bytes = [Text.Encoding]::UTF8.GetBytes($body)
$jwt2 = New-GhostJWT $adminKey
$r = Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/pages/$($p.id)/" -Method Put -Headers @{ Authorization="Ghost $jwt2"; 'Accept-Version'='v5.0' } -ContentType 'application/json' -Body $bytes -TimeoutSec 30
Write-Host ("UPDATED /membership/ (replaced {0} occurrences)." -f $count) -ForegroundColor Green
