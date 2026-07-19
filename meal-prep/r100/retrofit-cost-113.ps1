# retrofit-cost-113.ps1 - Adds the 3-part cost semantics to the ORIGINAL pre-R100 recipe posts.
# For each old recipe (slug NOT in specs-ready.txt):
#   1. compute the empty-pantry starter add from recipes-db grams x CURRENT board prices
#      (same BULK list + pantry-packages.json + walmart-preferred resolution as cost-engine)
#   2. in the live post html: clarify the Batch line, replace the True-line explanation with the
#      stocked-pantry wording, and insert the "Starting with an empty pantry" line
#      (first run = the post's PRINTED true cost + the computed add; never mixes eras inside a number)
#   3. PUT back as a single lexical html card, then re-fetch and verify.
# Accuracy rules: any bulk ingredient without a price basis SKIPS the whole recipe (reported, never
# guessed). Idempotent: posts already carrying the starter line are skipped.
# Usage: retrofit-cost-113.ps1 [-DryRun] [-Limit N]
param([switch]$DryRun,[int]$Limit=0)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$apiUrl='https://map-to-success.ghost.io'
$adminKey=(Get-Content (Join-Path $here '..\.ghostkey') -Raw).Trim()
$scratch='C:\Users\Owner\AppData\Local\Temp\claude\C--Codex\f3644374-5e4d-4c5e-a7e6-7ac3b89873f9\scratchpad\retro113'
if(-not (Test-Path $scratch)){ New-Item -ItemType Directory $scratch | Out-Null }

function New-GhostJWT {
  $p=$script:adminKey -split ':'; $sb=New-Object byte[] ($p[1].Length/2)
  for($i=0;$i -lt $sb.Length;$i++){ $sb[$i]=[Convert]::ToByte($p[1].Substring($i*2,2),16) }
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $h='{"alg":"HS256","typ":"JWT","kid":"'+$p[0]+'"}'; $pl='{"iat":'+$now+',"exp":'+($now+300)+',"aud":"/admin/"}'
  $b64={param($b)[Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_')}
  $si=(& $b64 ([Text.Encoding]::UTF8.GetBytes($h)))+'.'+(& $b64 ([Text.Encoding]::UTF8.GetBytes($pl)))
  $hm=New-Object System.Security.Cryptography.HMACSHA256 (,$sb)
  return $si+'.'+(& $b64 ($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes($si))))
}

# ---- price resolution: EXACTLY the cost-engine chain (weekly board walmart > recipe board walmart > feed cheapest),
# WITH UNIT RECONCILIATION (the brown-sugar 16x lesson: a map's gpu is calibrated to its era's board unit) ----
$UNIT_G=@{ lb=453.592; oz=28.3495; floz=29.57; kg=1000.0; g=1.0 }
function Resolve-Gpu([double]$gpu,[string]$mapUnit,[string]$rowUnit){
  if(-not $mapUnit -or -not $rowUnit -or $mapUnit -eq $rowUnit){ return $gpu }
  if($UNIT_G.ContainsKey($mapUnit) -and $UNIT_G.ContainsKey($rowUnit)){ return $gpu * ($UNIT_G[$rowUnit]/$UNIT_G[$mapUnit]) }
  return -1.0
}
$cmpFile = Get-ChildItem (Join-Path $here '..\..\grocery\out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1
$cmp = (Get-Content $cmpFile.FullName -Raw | ConvertFrom-Json).comparison
$board=@{}
foreach($row in $cmp){
  $wm = $row.stores | Where-Object { $_.store -eq 'Walmart' } | Select-Object -First 1
  $p=$null
  if($wm -and $wm.per_unit -gt 0){ $p=[double]$wm.per_unit }
  elseif($row.nomem_price -gt 0){ $p=[double]$row.nomem_price }
  if($p){ $board[$row.id]=@{ per_unit=$p; unit=[string]$row.unit } }
}
$rb = (Get-Content (Join-Path $here '..\..\grocery\out\recipe-board.json') -Raw | ConvertFrom-Json).comparison
foreach($row in $rb){
  if($board.ContainsKey($row.id)){ continue }
  $wm = $row.stores | Where-Object { $_.store -eq 'Walmart' } | Select-Object -First 1
  if($wm -and $wm.per_unit -gt 0){ $board[$row.id]=@{ per_unit=[double]$wm.per_unit; unit=[string]$row.unit } }
  elseif($row.cheapest_price -gt 0){ $board[$row.id]=@{ per_unit=[double]$row.cheapest_price; unit=[string]$row.unit } }
}
$feed = (Get-Content (Join-Path $here '..\..\grocery\out\smp-feed.json') -Raw | ConvertFrom-Json).ingredients
$feedMap=@{}
if($feed){ foreach($p in $feed.PSObject.Properties){ if($p.Value.cheapest -gt 0 -and -not $board.ContainsKey($p.Name)){ $feedMap[$p.Name]=@{ per_unit=[double]$p.Value.cheapest; unit=[string]$p.Value.unit } } } }

# item -> bid+gpu+unit (old 90-run map first for old recipes, then the r100 map)
$mapOld = (Get-Content (Join-Path $here '..\ingredient-map.json') -Raw | ConvertFrom-Json).mappings
$mapNew = (Get-Content (Join-Path $here 'r100-board-map.json') -Raw | ConvertFrom-Json).map
$itemBoard=@{}
foreach($m in $mapOld){ $itemBoard[$m.item] = @{ bid=$m.board_id; gpu=[double]$m.grams_per_unit; unit=[string]$m.unit } }
foreach($p in $mapNew.PSObject.Properties){ if(-not $itemBoard.ContainsKey($p.Name)){ $itemBoard[$p.Name] = @{ bid=$p.Value.bid; gpu=[double]$p.Value.gpu; unit=[string]$p.Value.unit } } }
# per-item unit override: old map priced ranch per PACKET ('each', 28g); the board row is per oz.
# A packet is 1oz of powder, so grams-per-oz is the correct current calibration.
if($itemBoard.ContainsKey('Ranch Seasoning Mix')){ $itemBoard['Ranch Seasoning Mix'].gpu=28.3495; $itemBoard['Ranch Seasoning Mix'].unit='oz' }

# BULK list: lifted verbatim from cost-engine.ps1 (single source; re-extract so they can never drift)
$engine = Get-Content (Join-Path $here 'cost-engine.ps1') -Raw
$mBulk=[regex]::Match($engine,'\$BULK\s*=\s*@\((?s)(.*?)\)\r?\n')
if(-not $mBulk.Success){ throw 'could not extract $BULK from cost-engine.ps1' }
$BULK=[regex]::Matches($mBulk.Groups[1].Value,"'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
$pantryPkg=@{}
foreach($p in ((Get-Content (Join-Path $here 'pantry-packages.json') -Raw | ConvertFrom-Json).packages).PSObject.Properties){
  $pantryPkg[$p.Name] = @{ g=[double]$p.Value.g; label=[string]$p.Value.label }
}

# ---- the target strings (must match the published 113 cards EXACTLY once each) ----
$OLD_TRUE_EXPL = ' This is what you actually pay when you buy whole packages, since you cannot grab a partial box, can, or jar, and you will have a little left over for next time. Pantry staples like rice, seasoning, and long-lasting sauces are counted at what this batch actually uses, because one package covers several batches.'
$NEW_TRUE_EXPL = ' What the register trip looks like if your pantry is already stocked. Meat, produce, and packaged items are counted as the whole packages you have to buy, since you cannot grab a partial box, can, or jar. Pantry staples you already own (rice, seasonings, oils, and long-lasting sauces) are counted at only what this batch uses.'
$BATCH_CLAR = ' This counts only the amounts this batch actually uses from each package, so it is the cost of the food in the containers, not a register receipt.'

$dbAll=(Get-Content (Join-Path $here '..\recipes-db.json') -Raw | ConvertFrom-Json).recipes
$newSlugs = Get-Content (Join-Path $here 'specs-ready.txt') | Where-Object { $_ }
$old = @($dbAll | Where-Object { $newSlugs -notcontains $_.slug })
Write-Output ("old recipes to retrofit: " + $old.Count)
if($Limit -gt 0){ $old = $old | Select-Object -First $Limit }

$ok=0; $skipped=@(); $failed=@()
foreach($r in $old){
  # 1) pantry starter add from CURRENT prices
  $bulkUtil=0.0; $outlay=0.0; $bad=$null
  foreach($ing in $r.ingredients){
    if($BULK -notcontains $ing.item){ continue }
    $g=[double]$ing.grams; if($g -le 0){ continue }
    $b=$itemBoard[$ing.item]
    $ppg=$null
    if($b){
      $src=$null
      if($board.ContainsKey($b.bid)){ $src=$board[$b.bid] }
      elseif($feedMap.ContainsKey($b.bid)){ $src=$feedMap[$b.bid] }
      if($src){
        $eg = Resolve-Gpu $b.gpu $b.unit $src.unit
        if($eg -le 0){ $bad=('unit mismatch: '+$ing.item+' map '+$b.unit+' vs '+$src.unit); break }
        $ppg=$src.per_unit/$eg
      }
    }
    if($null -eq $ppg){ $bad=('no price basis: '+$ing.item); break }
    if(-not $pantryPkg.ContainsKey($ing.item)){ $bad=('no pantry package: '+$ing.item); break }
    $pp=$pantryPkg[$ing.item]
    $util=[Math]::Round($g*$ppg,2)
    $n=[Math]::Ceiling(($g/$pp.g)-0.02); if($n -lt 1){ $n=1 }
    $st=[Math]::Round($n*$pp.g*$ppg,2); if($st -lt $util){ $st=$util }
    $bulkUtil+=$util; $outlay+=$st
  }
  if($bad){ $skipped += ($r.slug + ' :: ' + $bad); continue }
  $add=[Math]::Round($outlay-$bulkUtil,2)
  # add=0 (no pantry staples at all): still apply the copy clarifications, just no starter line

  # 2) fetch + splice
  $jwt=New-GhostJWT
  $hdr=@{ Authorization="Ghost $jwt"; 'Accept-Version'='v5.0' }
  $post=$null
  try { $post=(Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$($r.slug)/?formats=html&fields=id,html,updated_at,title" -Headers $hdr -TimeoutSec 30).posts[0] } catch {}
  if(-not $post){ $failed += ($r.slug + ' :: post fetch failed'); continue }
  $html=[string]$post.html
  $html=$html -replace '<!--kg-card-(begin|end): html-->',''
  if($html -match 'Starting with an empty pantry'){ $ok++; continue }   # already retrofitted

  # printed true cost (the number the new line must reference)
  $mt=[regex]::Match($html,'<strong>True shopping cost: about \$([0-9]+\.[0-9]{2}) across 14 servings, roughly \$([0-9]+\.[0-9]{2}) per bowl\.</strong>')
  $starterLi=''
  if($mt.Success){
    # standard (90-run/R100 format) card
    if(([regex]::Matches($html,[regex]::Escape($OLD_TRUE_EXPL))).Count -ne 1){ $failed += ($r.slug + ' :: true explanation text not exactly once'); continue }
    $printedTrue=[double]$mt.Groups[1].Value
    $firstRun=[Math]::Round($printedTrue+$add,2)
    $mb=[regex]::Match($html,'(<li><strong>Batch total: about \$[0-9]+\.[0-9]{2} across 14 servings, so roughly \$[0-9]+\.[0-9]{2} per bowl\.</strong>)(</li>)')
    if(-not $mb.Success){ $failed += ($r.slug + ' :: batch line not found'); continue }
    $html = $html.Replace($mb.Groups[0].Value, $mb.Groups[1].Value + $BATCH_CLAR + '</li>')
    $html = $html.Replace($OLD_TRUE_EXPL, $NEW_TRUE_EXPL)
    if($add -gt 0){
      $trueLiEnd = $html.IndexOf('</li>', $html.IndexOf($mt.Groups[0].Value)) + 5
      $starterLi = '<li><strong>Starting with an empty pantry? Add about $' + $add.ToString('0.00') + ' one time.</strong> That is the extra cost of buying full containers of every pantry staple in this recipe instead of just the amounts used, which puts a first shopping trip near $' + $firstRun.ToString('0.00') + '. Those containers then feed this batch and many more after it.</li>'
      $html = $html.Substring(0,$trueLiEnd) + $starterLi + $html.Substring($trueLiEnd)
    }
    if($DryRun){ Write-Output ("DRY {0}: add={1} true={2} firstrun={3}" -f $r.slug,$add,$printedTrue,$firstRun); $ok++; continue }
  } else {
    # pilot-era variant (fajita): single batch line "Batch total: ~$X at 14 servings, about $Y per serving",
    # no true-cost line. Append the clarifier and a starter line WITHOUT a first-trip total (no true
    # number exists on the page to anchor it; never mix computation eras inside a printed number).
    $mb=[regex]::Match($html,'(<li><strong>Batch total: ~\$[0-9.]+ at 14 servings, about \$[0-9.]+ per serving</strong>)(</li>)')
    if(-not $mb.Success){ $failed += ($r.slug + ' :: no recognizable batch line'); continue }
    $html = $html.Replace($mb.Groups[0].Value, $mb.Groups[1].Value + $BATCH_CLAR + '</li>')
    if($add -gt 0){
      $liEnd = $html.IndexOf('</li>', $html.IndexOf($mb.Groups[1].Value)) + 5
      $starterLi = '<li><strong>Starting with an empty pantry? Add about $' + $add.ToString('0.00') + ' one time.</strong> That buys full containers of the pantry staples in this recipe instead of just the amounts used, and those containers feed this batch and many more after it.</li>'
      $html = $html.Substring(0,$liEnd) + $starterLi + $html.Substring($liEnd)
    }
    if($DryRun){ Write-Output ("DRY {0}: add={1} (pilot-variant, no true line)" -f $r.slug,$add); $ok++; continue }
  }

  # backup + PUT
  $html | Set-Content (Join-Path $scratch ($r.slug + '.new.html')) -Encoding UTF8
  $lexObj=@{root=[ordered]@{children=@([ordered]@{type='html';version=1;html=[string]$html});direction=$null;format='';indent=0;type='root';version=1}}
  $lex=ConvertTo-Json $lexObj -Depth 12 -Compress
  $bodyJson=@{ posts=@(@{ lexical=$lex; updated_at=$post.updated_at }) } | ConvertTo-Json -Depth 14
  $jwt=New-GhostJWT
  try {
    Invoke-RestMethod -Method PUT -Uri "$apiUrl/ghost/api/admin/posts/$($post.id)/" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0';'Content-Type'='application/json'} -Body ([Text.Encoding]::UTF8.GetBytes($bodyJson)) -TimeoutSec 60 | Out-Null
  } catch { $failed += ($r.slug + ' :: PUT failed ' + $_.Exception.Message); continue }

  # 3) verify: refetch, confirm every edit that applies to this card landed
  Start-Sleep -Milliseconds 300
  $jwt=New-GhostJWT
  $chk=(Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$($r.slug)/?formats=html&fields=html" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -TimeoutSec 30).posts[0].html
  $good = ($chk -match [regex]::Escape($BATCH_CLAR.Substring(1,60))) -and ($chk -notmatch [regex]::Escape($OLD_TRUE_EXPL.Substring(1,60)))
  if($starterLi){ $good = $good -and ($chk -match [regex]::Escape($starterLi.Substring(0,80))) }
  if($mt.Success){ $good = $good -and ($chk -match [regex]::Escape($NEW_TRUE_EXPL.Substring(1,60))) }
  if($good){ $ok++; Write-Output ("OK  {0}  add={1}" -f $r.slug,$add) }
  else { $failed += ($r.slug + ' :: live verify failed') }
}
Write-Output ("retrofitted OK: $ok / $($old.Count)")
if($skipped){ Write-Output 'SKIPPED:'; $skipped | ForEach-Object { "  $_" } }
if($failed){ Write-Output 'FAILED:'; $failed | ForEach-Object { "  $_" } }
