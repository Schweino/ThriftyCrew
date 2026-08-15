$ErrorActionPreference="Stop"
. "C:\Codex\.claude\skills\lesson\ghost-config.ps1"
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
function JStr($s){ $sb=New-Object System.Text.StringBuilder ($s.Length+16); [void]$sb.Append('"')
  foreach($ch in $s.ToCharArray()){ switch($ch){ '"'{[void]$sb.Append('\"');break} '\'{[void]$sb.Append('\\');break} "`n"{[void]$sb.Append('\n');break} "`r"{[void]$sb.Append('\r');break} "`t"{[void]$sb.Append('\t');break} default{ if([int]$ch -lt 0x20){[void]$sb.AppendFormat('\u{0:x4}',[int]$ch)}else{[void]$sb.Append($ch)} } } }
  [void]$sb.Append('"'); return $sb.ToString() }
$EM=[string][char]0x2014
function DeDash($s){
  $t = $s -replace '&mdash;','X_EMDASH_X'; $t=$t.Replace($EM,'X_EMDASH_X')
  $t = [regex]::Replace($t, ' X_EMDASH_X ([^<>"]{1,120}?) X_EMDASH_X ', ', $1, ')
  $t = [regex]::Replace($t, ' +X_EMDASH_X +([^<\s"])', { param($m) $c=$m.Groups[1].Value; if($c -match '[a-z]'){'. '+$c.ToUpper()}else{'. '+$c} })
  $t = $t -replace ' ?X_EMDASH_X ?', ', '; return $t }
function Get-H { return @{Authorization="Ghost $(New-GhostJWT $adminKey)";'Accept-Version'='v5.0'} }

$idx = Get-Content "C:\Codex\backups\voice-rewrite\recipes-about-index.json" -Raw | ConvertFrom-Json
$root="C:\Codex\backups\voice-rewrite"
$published=0; $flagged=@()
foreach($it in $idx){
  if($it.kind -ne 'post'){ continue }  # recipes only; About handled manually
  $slug=$it.slug
  $rewFile="$root\rewrites\$slug.html"
  if(-not (Test-Path $rewFile)){ $flagged+=("$slug :: no rewrite file"); continue }
  $orig=[IO.File]::ReadAllText("$root\current\$slug.html",[Text.Encoding]::UTF8)
  $new =DeDash ([IO.File]::ReadAllText($rewFile,[Text.Encoding]::UTF8))
  $problems=@()
  if($new.Trim().Length -lt 120){ $problems+='too short' }
  if($new.Contains($EM)){ $problems+='em dash' }
  # EVERY number token must be preserved (quantities, times, temps, macros)
  $nums = [regex]::Matches($orig,'\d+') | ForEach-Object { $_.Value } | Group-Object | ForEach-Object { $_.Name }
  $origText=($orig -replace '<[^>]+>',' '); $newText=($new -replace '<[^>]+>',' ')
  $lost = @()
  foreach($n in ($nums | Select-Object -Unique)){
    $co=([regex]::Matches($origText,('(?<!\d)'+[regex]::Escape($n)+'(?!\d)'))).Count
    $cn=([regex]::Matches($newText,('(?<!\d)'+[regex]::Escape($n)+'(?!\d)'))).Count
    if($cn -lt $co){ $lost += ("$n($co->$cn)") }
  }
  if($lost.Count){ $problems += ('numbers changed: '+($lost -join ',')) }
  $wo=($orig -replace '<[^>]+>',' ' -split '\s+').Count; $wn=($new -replace '<[^>]+>',' ' -split '\s+').Count
  if($wo -gt 0 -and ($wn -lt $wo*0.55 -or $wn -gt $wo*1.5)){ $problems += "words $wo->$wn" }
  if($problems.Count){ $flagged += ("$slug :: " + ($problems -join ' | ')); continue }
  $H=Get-H
  $ua=(Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/$($it.id)/?fields=updated_at" -Headers $H).posts[0].updated_at
  $payload='{"posts":[{"html":'+(JStr $new)+',"updated_at":'+(JStr $ua)+'}]}'
  $bytes=[Text.Encoding]::UTF8.GetBytes($payload)
  try{ $null=Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/$($it.id)/?source=html" -Method Put -Headers $H -ContentType 'application/json' -Body $bytes -TimeoutSec 30; $published++; Write-Host ("  PUBLISHED  {0}" -f $slug) -ForegroundColor Green }
  catch{ $flagged += ("$slug :: PUT FAIL " + $_.Exception.Message) }
}
Write-Host ("`nRECIPES: published={0}  flagged={1}" -f $published,$flagged.Count) -ForegroundColor Cyan
if($flagged.Count){ $flagged | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow } }