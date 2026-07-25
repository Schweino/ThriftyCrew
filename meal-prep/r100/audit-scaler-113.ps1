# audit-scaler-113.ps1 - Audits the LIVE scaler payloads of the 113 pre-r100 recipe cards for the same
# unit-reconciliation bug fixed on the r100 set (map-era gpu vs live feed/board unit; PIPELINE FIX 2).
# Read-only: fetches admin html, extracts the smp-sc-data JSON, checks every priced entry's gpu against
# the merged map calibration rescaled to the unit the live price source quotes. Report only, no writes.
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$apiUrl = 'https://map-to-success.ghost.io'
$adminKey = (Get-Content (Join-Path $here '..\.ghostkey') -Raw).Trim()

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

# merged map (r100 precedence) keyed by item AND by bid (old payloads predate some item renames)
$byItem=@{}; $byBid=@{}
$mapNew = (Get-Content (Join-Path $here 'r100-board-map.json') -Raw | ConvertFrom-Json).map
foreach($p in $mapNew.PSObject.Properties){ $e=@{ bid=[string]$p.Value.bid; gpu=[double]$p.Value.gpu; unit=[string]$p.Value.unit }; $byItem[$p.Name]=$e; if(-not $byBid.ContainsKey($e.bid)){ $byBid[$e.bid]=$e } }
$mapOldM = (Get-Content (Join-Path $here '..\ingredient-map.json') -Raw | ConvertFrom-Json).mappings
foreach($m in $mapOldM){ $e=@{ bid=[string]$m.board_id; gpu=[double]$m.grams_per_unit; unit=[string]$m.unit }; if(-not $byItem.ContainsKey($m.item)){ $byItem[$m.item]=$e }; if(-not $byBid.ContainsKey($e.bid)){ $byBid[$e.bid]=$e } }

$feedUnit=@{}
$feed = (Get-Content (Join-Path $here '..\..\grocery\out\smp-feed.json') -Raw | ConvertFrom-Json).ingredients
if($feed){ foreach($p in $feed.PSObject.Properties){ if($p.Value.unit){ $feedUnit[$p.Name]=[string]$p.Value.unit } } }
$boardUnit=@{}
$cmpFile = Get-ChildItem (Join-Path $here '..\..\grocery\out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1
foreach($row in ((Get-Content $cmpFile.FullName -Raw | ConvertFrom-Json).comparison)){ $boardUnit[$row.id]=[string]$row.unit }
$rbFile = Join-Path $here '..\..\grocery\out\recipe-board.json'
if(Test-Path $rbFile){
  foreach($row in ((Get-Content $rbFile -Raw | ConvertFrom-Json).comparison)){ if(-not $boardUnit.ContainsKey($row.id)){ $boardUnit[$row.id]=[string]$row.unit } }
}
$UNIT_G=@{ lb=453.592; oz=28.3495; floz=29.57; kg=1000.0; g=1.0 }

$slugs = Get-Content (Join-Path $here 'old-113-slugs.txt') | Where-Object { $_ }
$bugs=@(); $flags=@(); $noPayload=@(); $okCards=0; $bugItemCount=@{}
foreach($slug in $slugs){
  $jwt = New-GhostJWT $adminKey
  try {
    $post = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$slug/?formats=html&fields=html" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -TimeoutSec 30).posts[0]
  } catch { $flags += ("$slug FETCH FAIL :: " + $_.Exception.Message); continue }
  $m = [regex]::Match([string]$post.html, 'class="smp-sc-data">\s*(\{.*?\})\s*</script>', 'Singleline')
  if(-not $m.Success){ $noPayload += $slug; continue }
  $data = $m.Groups[1].Value | ConvertFrom-Json
  $cardBug=$false
  foreach($ing in $data.ing){
    if(-not ($ing.PSObject.Properties.Name -contains 'bid') -or -not $ing.bid){ continue }
    $bid=[string]$ing.bid
    $e = $null
    if($byItem.ContainsKey([string]$ing.item) -and $byItem[[string]$ing.item].bid -eq $bid){ $e=$byItem[[string]$ing.item] }
    elseif($byBid.ContainsKey($bid)){ $e=$byBid[$bid] }
    if(-not $e){ $flags += ("$slug :: $($ing.item) [$bid] no map row - cannot audit"); continue }
    $rowUnit=$null
    if($feedUnit.ContainsKey($bid)){ $rowUnit=$feedUnit[$bid] } elseif($boardUnit.ContainsKey($bid)){ $rowUnit=$boardUnit[$bid] }
    if(-not $rowUnit){ $flags += ("$slug :: $($ing.item) [$bid] not in feed/board - widget shows fallback"); continue }
    if(-not $e.unit -or -not $UNIT_G.ContainsKey($e.unit) -or -not $UNIT_G.ContainsKey($rowUnit)){
      if($e.unit -ne $rowUnit){ $flags += ("$slug :: $($ing.item) [$bid] NON-STANDARD units map=$($e.unit) live=$rowUnit gpu=$($ing.gpu)") }
      continue
    }
    $expected = $e.gpu * ($UNIT_G[$rowUnit]/$UNIT_G[$e.unit])
    $g=[double]$ing.gpu
    if([Math]::Abs($g-$expected)/$expected -gt 0.005){
      $bugs += ("$slug :: $($ing.item) [$bid] live gpu=$g expected=$([Math]::Round($expected,3)) (map $($e.unit) -> live $rowUnit, off x$([Math]::Round($expected/$g,3)))")
      $bugItemCount[$ing.item + ' [' + $bid + ']']++
      $cardBug=$true
    }
  }
  if(-not $cardBug){ $okCards++ }
}
Write-Output ("== old-113 live scaler audit ==")
Write-Output ("cards clean: $okCards / $($slugs.Count); cards w/o scaler payload: $($noPayload.Count); bug entries: $($bugs.Count)")
if($noPayload){ Write-Output ("no payload: " + ($noPayload -join ', ')) }
if($bugs){
  Write-Output ""
  Write-Output "-- BUG ENTRIES --"
  $bugs | ForEach-Object { Write-Output ("  " + $_) }
  Write-Output ""
  Write-Output "-- distinct items --"
  $bugItemCount.GetEnumerator() | Sort-Object Name | ForEach-Object { Write-Output ("  {0}  x{1}" -f $_.Key,$_.Value) }
}
if($flags){
  Write-Output ""
  Write-Output "-- FLAGS (not auditable / non-standard) --"
  $flags | Sort-Object -Unique | ForEach-Object { Write-Output ("  " + $_) }
}
$bugs | Out-File (Join-Path $here 'audit-113-bugs.txt') -Encoding utf8
