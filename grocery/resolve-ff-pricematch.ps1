<#
  resolve-ff-pricematch.ps1 - For each Family Fare cell in out\link-price-mismatch.json, re-pick the FF product
  whose per-unit MATCHES the board price (so the "See item" link lands on the same product the price is for).
  Queries the Freshop API, keeps only products of the right TYPE (name must contain the commodity's head word),
  then chooses the candidate whose per-unit is closest to the board's - and only if within tolerance. Cells with
  NO in-tolerance match are reported (their board price is likely the stale/wrong side, not the link).
  Writes out\url-inputs\store-ff8-urls.json.
#>
param([double]$Tol = 0.30, [string]$OutDir = "")
$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
. (Join-Path $root 'commodity-search.json') > $null 2>&1
$terms = (Get-Content (Join-Path $root 'commodity-search.json') -Raw | ConvertFrom-Json).terms
$mm = @(Get-Content (Join-Path $OutDir 'link-price-mismatch.json') -Raw | ConvertFrom-Json) | Where-Object { $_.store -eq 'Family Fare' }
function PerUnit([string]$size,[string]$unit,[double]$price){ if($price -le 0){return $null}
 $s=([string]$size).ToLower(); $m=[regex]::Match($s,'([0-9]+(?:\.[0-9]+)?)'); $n=if($m.Success){[double]$m.Groups[1].Value}else{1}; if($n -le 0){$n=1}
 $pk=[regex]::Match($s,'([0-9]+)\s*(pk|pack|ct|ea)\b'); $mult=if($pk.Success -and ($s -match 'oz|lb|fl')){[double]$pk.Groups[1].Value}else{1}
 switch($unit){ 'lb'{if($s -match 'lb|pound'){return $price/$n}; if($s -match 'oz'){return $price/($n/16)}; return $price}
  'oz'{if($s -match 'gal'){return $price/(128*$n)}; if($s -match 'lb|pound'){return $price/(16*$n)}; if($s -match 'oz'){return $price/($n*$mult)}; return $null}
  'floz'{if($s -match 'gal'){return $price/(128*$n)}; if($s -match 'oz'){return $price/($n*$mult)}; if($s -match '\bl\b|liter'){return $price/(33.8*$n)}; return $null}
  'each'{if($s -match 'lb|pound'){return $null}; if($s -match 'ct|ea|each|pk'){return $price/$n}; return $price}
  default{return $price/$n} } }
$rows=New-Object System.Collections.Generic.List[object]; $noMatch=New-Object System.Collections.Generic.List[object]
foreach($c in $mm){ $id=[string]$c.id; $unit=[string]$c.unit; $board=[double]$c.board
 $q = if($terms.PSObject.Properties[$id]){[string]$terms.$id}else{$id -replace '-',' '}
 $head = ($id -replace '-',' ' -split ' ' | Where-Object { $_.Length -gt 2 } | Select-Object -Last 1)
 $api='https://api.freshop.ncrcloud.com/1/products?app_key=family_fare&store_id=6401&limit=25&q='+[uri]::EscapeDataString($q)
 $best=$null
 try{ $items=@(((Invoke-WebRequest -Uri $api -UseBasicParsing -TimeoutSec 20 -Headers @{'User-Agent'='Mozilla/5.0';'Accept'='application/json'}).Content|ConvertFrom-Json).items)
  foreach($p in $items){ $nm=([string]$p.name).ToLower(); if($head -and $nm -notmatch [regex]::Escape($head)){ continue }
   $pr=0.0; if($p.base_price){[void][double]::TryParse(([string]$p.base_price),[ref]$pr)}; if($pr -le 0){continue}
   $pu=PerUnit ([string]$p.size) $unit $pr; if($null -eq $pu -or $pu -le 0){continue}
   $off=[math]::Abs($pu-$board)/$board
   if($null -eq $best -or $off -lt $best.off){ $best=@{off=$off;url=$p.canonical_url;price=$pr;size=$p.size;name=$p.name;pu=$pu} } } }catch{}
 Start-Sleep -Milliseconds 250
 if($best -and $best.off -le $Tol){ $rows.Add([pscustomobject]@{id=$id;url=$best.url;price=[math]::Round($best.price,2);size=$best.size;name=$best.name}); "OK   {0,-22} board={1} link={2} ({3}%) {4}" -f $id,$board,[math]::Round($best.pu,3),[math]::Round($best.off*100),$best.name }
 else{ $noMatch.Add([pscustomobject]@{id=$id;board=$board;closest=$(if($best){[math]::Round($best.pu,3)}else{'none'})}); "MISS {0,-22} board={1} closest={2} -> board price likely wrong, leaving link hidden" -f $id,$board,$(if($best){[math]::Round($best.pu,3)}else{'none'}) }
}
$dir=Join-Path $OutDir 'url-inputs'; ($rows|ConvertTo-Json -Depth 4)|Set-Content (Join-Path $dir 'store-ff8-urls.json') -Encoding UTF8
"---- matched $($rows.Count) / $($mm.Count) FF cells; $($noMatch.Count) no in-tolerance match (board-price suspects)"