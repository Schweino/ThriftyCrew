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

$root="C:\Codex\backups\voice-rewrite"
$idx = Get-Content "$root\lessons-index.json" -Raw | ConvertFrom-Json
$published=0; $flagged=@(); $missing=@()
foreach($it in $idx){
  $slug=$it.slug
  $curFile="$root\current\$slug.html"; $rewFile="$root\rewrites\$slug.html"
  if(-not (Test-Path $rewFile)){ $missing += $slug; continue }
  $orig=[IO.File]::ReadAllText($curFile,[Text.Encoding]::UTF8)
  $new =[IO.File]::ReadAllText($rewFile,[Text.Encoding]::UTF8)
  $new = DeDash $new   # safety net: strip any stray em dashes
  $problems=@()
  # 1. non-empty
  if($new.Trim().Length -lt 200){ $problems += 'too short' }
  # 2. H2 count within 1
  $h2o=([regex]::Matches($orig,'<h2')).Count; $h2n=([regex]::Matches($new,'<h2')).Count
  if([Math]::Abs($h2o-$h2n) -gt 1){ $problems += "h2 $h2o->$h2n" }
  # 3. no em dashes
  if($new.Contains($EM)){ $problems += 'em dash remains' }
  # 4. dollar amounts + percentages preserved
  $money = [regex]::Matches($orig,'\$[0-9][0-9,]*(\.[0-9]+)?') | ForEach-Object { $_.Value } | Select-Object -Unique
  $pct   = [regex]::Matches($orig,'[0-9]+(\.[0-9]+)?%') | ForEach-Object { $_.Value } | Select-Object -Unique
  $lostM = @($money | Where-Object { -not $new.Contains($_) })
  $lostP = @($pct   | Where-Object { -not $new.Contains($_) })
  if($lostM.Count){ $problems += ('lost $: '+($lostM -join ',')) }
  if($lostP.Count){ $problems += ('lost %: '+($lostP -join ',')) }
  # 5. word count 60-140%
  $wo=($orig -replace '<[^>]+>',' ' -split '\s+').Count; $wn=($new -replace '<[^>]+>',' ' -split '\s+').Count
  if($wo -gt 0 -and ($wn -lt $wo*0.6 -or $wn -gt $wo*1.4)){ $problems += "words $wo->$wn" }
  # 6. questions block if original had it
  if($orig -match 'Questions to sit with' -and $new -notmatch 'Questions to sit with'){ $problems += 'lost Questions block' }

  if($problems.Count){ $flagged += ("$slug :: " + ($problems -join ' | ')); continue }

  # PUBLISH via source=html (fresh updated_at to avoid collision)
  $H=Get-H
  $ua=(Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/$($it.id)/?fields=updated_at" -Headers $H).posts[0].updated_at
  $payload='{"posts":[{"html":'+(JStr $new)+',"updated_at":'+(JStr $ua)+'}]}'
  $bytes=[Text.Encoding]::UTF8.GetBytes($payload)
  try{
    $null=Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/$($it.id)/?source=html" -Method Put -Headers $H -ContentType 'application/json' -Body $bytes -TimeoutSec 30
    $published++; Write-Host ("  PUBLISHED  {0}" -f $slug) -ForegroundColor Green
  } catch { $flagged += ("$slug :: PUT FAIL " + $_.Exception.Message) }
}
Write-Host ""
Write-Host ("PUBLISHED={0}  FLAGGED={1}  MISSING_REWRITE={2}  (of {3})" -f $published,$flagged.Count,$missing.Count,$idx.Count) -ForegroundColor Cyan
if($flagged.Count){ Write-Host "FLAGGED (left on original, not published):" -ForegroundColor Yellow; $flagged | ForEach-Object { Write-Host "  $_" } }
if($missing.Count){ Write-Host "MISSING REWRITE FILES:" -ForegroundColor Yellow; $missing | ForEach-Object { Write-Host "  $_" } }