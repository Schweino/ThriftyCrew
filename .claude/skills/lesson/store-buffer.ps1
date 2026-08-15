<#
  store-buffer.ps1
  Stages the full code-injection HTML into a scratch draft post's codeinjection_foot
  field via the Admin API. Builds the JSON body by hand (not ConvertTo-Json) because
  PS 5.1's ConvertTo-Json is quadratic-time on large strings and hangs on ~45KB content.
#>
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
function JStr($s) {
  # Fast manual JSON string escaping (avoids ConvertTo-Json's quadratic slowdown on large strings)
  $sb = New-Object System.Text.StringBuilder ($s.Length + 16)
  [void]$sb.Append('"')
  foreach ($ch in $s.ToCharArray()) {
    switch ($ch) {
      '"'  { [void]$sb.Append('\"'); break }
      '\'  { [void]$sb.Append('\\'); break }
      "`n" { [void]$sb.Append('\n'); break }
      "`r" { [void]$sb.Append('\r'); break }
      "`t" { [void]$sb.Append('\t'); break }
      default {
        if ([int]$ch -lt 0x20) { [void]$sb.AppendFormat('\u{0:x4}', [int]$ch) }
        else { [void]$sb.Append($ch) }
      }
    }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}

$injectionFile = "C:\Users\Owner\AppData\Local\Temp\claude\C--Codex\f3644374-5e4d-4c5e-a7e6-7ac3b89873f9\scratchpad\new-injection-head.txt"
$content = [IO.File]::ReadAllText($injectionFile, [Text.Encoding]::UTF8)
Write-Host "Injection content length: $($content.Length)" -ForegroundColor DarkGray

Write-Host "Checking for existing buffer post..." -ForegroundColor DarkGray
$jwt = New-GhostJWT $adminKey
$existingId = $null
$existingUpdatedAt = $null
try {
  $r = Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/zz-inject-buffer/?fields=id,updated_at" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -TimeoutSec 20
  $existingId = $r.posts[0].id
  $existingUpdatedAt = $r.posts[0].updated_at
  Write-Host "  found existing post id=$existingId" -ForegroundColor DarkGray
} catch { Write-Host "  (none found, will create)" -ForegroundColor DarkGray }

$emptyLex = '{"root":{"children":[{"type":"paragraph","version":1,"children":[]}],"direction":null,"format":"","indent":0,"type":"root","version":1}}'

Write-Host "Building JSON body manually..." -ForegroundColor DarkGray
$sw = [Diagnostics.Stopwatch]::StartNew()
$fields = New-Object System.Collections.Generic.List[string]
$fields.Add('"title":' + (JStr 'ZZ Inject Buffer (do not publish)'))
$fields.Add('"slug":' + (JStr 'zz-inject-buffer'))
$fields.Add('"lexical":' + (JStr $emptyLex))
$fields.Add('"status":' + (JStr 'draft'))
$fields.Add('"codeinjection_foot":' + (JStr $content))
if ($existingId) { $fields.Add('"updated_at":' + (JStr $existingUpdatedAt)) }
$postJson = '{' + ($fields -join ',') + '}'
$bodyJson = '{"posts":[' + $postJson + ']}'
$sw.Stop()
Write-Host ("JSON built in {0}ms, totalBytes={1}" -f $sw.ElapsedMilliseconds, $bodyJson.Length) -ForegroundColor DarkGray

# Validate it round-trips before sending
$null = $bodyJson | ConvertFrom-Json

if ($existingId) { $method='Put'; $uri="$apiUrl/ghost/api/admin/posts/$existingId/" }
else { $method='Post'; $uri="$apiUrl/ghost/api/admin/posts/" }

$bytes = [Text.Encoding]::UTF8.GetBytes($bodyJson)
Write-Host "Sending $method to Ghost, bodyBytes=$($bytes.Length)..." -ForegroundColor DarkGray
$jwt2 = New-GhostJWT $adminKey
$result = Invoke-RestMethod -Uri $uri -Method $method -Headers @{Authorization="Ghost $jwt2";'Accept-Version'='v5.0'} -ContentType 'application/json' -Body $bytes -TimeoutSec 30
Write-Host ("Buffer stored. contentLength={0}  postId={1}" -f $content.Length, $result.posts[0].id) -ForegroundColor Green
