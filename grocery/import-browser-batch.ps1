<#
  import-browser-batch.ps1 - turn a browser-captured price file (from the iframe-loop capture staged in the
  page and downloaded) into <store>-regular rows that compare-deals matches by the SAME include/exclude/band
  rules it uses for every other cell. The capture supplies priced candidates ONLY; matching stays PowerShell-side.

  Input format (tab + delimited, one line per commodity):  <id>\t<name>::<price>|<name>::<price>|...
  The capture already include-filtered to each commodity, so cross-commodity pollution is bounded (like the
  headless primer); compare-deals still applies the full exclude + band + per-unit, and diff-board catches any
  residual collision.

  Usage: .\import-browser-batch.ps1 -Store "Baker's" -Raw out\staples500\bakers-batch1-raw.txt
  Then: compare-deals -> diff-board (vs clean baseline) -> audit-food-category -> build-vet-sheet.
#>
param([Parameter(Mandatory=$true)][string]$Store, [Parameter(Mandatory=$true)][string]$Raw, [string]$SourceLabel = "")
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$today=(Get-Date).ToString('yyyy-MM-dd')
$regDir=Join-Path $root 'out\regular'
if(-not $SourceLabel){ $SourceLabel = "$Store search (batch capture, Omaha)" }
# store -> regular file prefix
$prefix = switch ($Store) { "Baker's" {'bakers-regular'} "Walmart" {'walmart-regular'} "Sam's Club" {'sams-regular'} "Aldi" {'aldi-regular'} "Fareway" {'fareway-regular'} default { ($Store.ToLower() -replace '[^a-z0-9]','') + '-regular' } }

function Parse-Size([string]$nm){
  # multipack "4-15 oz" -> "4 pk 15 oz"
  $m=[regex]::Match($nm,'(\d+)\s*-\s*(\d+(?:\.\d+)?)\s*(fl\s*oz|oz|lb)','IgnoreCase')
  if($m.Success){ return ($m.Groups[1].Value + ' pk ' + $m.Groups[2].Value + ' ' + (($m.Groups[3].Value.ToLower()) -replace '\s+',' ')) }
  # "N pk ... M oz"
  $mp=[regex]::Match($nm,'(\d+)\s*(?:pk|pack|ct|count)\b','IgnoreCase')
  $mu=[regex]::Match($nm,'(\d+(?:\.\d+)?)\s*(fl\s*oz|floz|oz|lb|gallon|gal|qt|pt)\b','IgnoreCase')
  if($mp.Success -and $mu.Success -and [int]$mp.Groups[1].Value -gt 1){ return ($mp.Groups[1].Value + ' pk ' + $mu.Groups[1].Value + ' ' + (($mu.Groups[2].Value.ToLower()) -replace '\s+',' ')) }
  if($mu.Success){ return ($mu.Groups[1].Value + ' ' + (($mu.Groups[2].Value.ToLower()) -replace '\s+',' ')) }
  return ''
}

$lines = Get-Content (Join-Path $root $Raw)
$rows=New-Object System.Collections.ArrayList
$seen=@{}; $noSize=0
foreach($ln in $lines){
  if(-not ($ln -match "`t")){ continue }
  $parts=$ln -split "`t",2
  $prodStr=[string]$parts[1]
  foreach($p in ($prodStr -split '\|')){
    $i=$p.LastIndexOf('::'); if($i -lt 0){ continue }
    $nm=(($p.Substring(0,$i)).Trim() -replace '\s+title\s*$','' -replace '\s+NET\s+WT\s*$','').Trim()
    $price=0.0; [void][double]::TryParse((($p.Substring($i+2)) -replace '[^0-9.]',''),[ref]$price)
    if($price -le 0 -or -not $nm){ continue }
    $size=Parse-Size $nm
    if(-not $size){ $noSize++; continue }
    $key=($nm+'|'+$size).ToLower(); if($seen.ContainsKey($key)){ continue }; $seen[$key]=$true
    [void]$rows.Add([ordered]@{ store=$Store; item=$nm; ad_price=('$'+$price); size=$size; regular=$price; current_price=$price; source_ad=$SourceLabel; as_of=$today })
  }
}

# ADD-only merge into today's <store>-regular file (never removes/overwrites an existing row)
$prev=Get-ChildItem (Join-Path $regDir ($prefix+'-*.json')) -EA SilentlyContinue | Where-Object { $_.BaseName -match ('^'+[regex]::Escape($prefix)+'-\d{4}-\d{2}-\d{2}$') } | Sort-Object Name -Descending | Select-Object -First 1
$merged=New-Object System.Collections.ArrayList; $mseen=@{}
$doc=$null
if($prev){ $doc=Get-Content $prev.FullName -Raw|ConvertFrom-Json; foreach($r in @($doc.deals)){ [void]$merged.Add($r); $mseen[(([string]$r.item)+'|'+([string]$r.size)).ToLower()]=$true } }
$added=0
foreach($r in $rows){ $k=(([string]$r.item)+'|'+([string]$r.size)).ToLower(); if($mseen.ContainsKey($k)){continue}; $mseen[$k]=$true; [void]$merged.Add([pscustomobject]$r); $added++ }
$outFile=Join-Path $regDir ($prefix+"-$today.json")
if($doc){ $doc.deals=$merged.ToArray(); if($doc.PSObject.Properties['deal_count']){$doc.deal_count=$merged.Count}else{$doc|Add-Member deal_count $merged.Count -Force}; ($doc|ConvertTo-Json -Depth 6)|Set-Content $outFile -Encoding UTF8 }
else { ([ordered]@{ store=$Store; week_of=$today; price_type='everyday'; price_mode='in-store'; deal_count=$merged.Count; deals=$merged.ToArray() }|ConvertTo-Json -Depth 6)|Set-Content $outFile -Encoding UTF8 }
Write-Output ("$Store : parsed $($rows.Count) sized rows ($noSize skipped no-size), added $added new, total $($merged.Count) -> $(Split-Path $outFile -Leaf)")
