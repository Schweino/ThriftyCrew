<#
  import-browser-batch.ps1 - turn a browser-captured price file (from the iframe-loop capture staged in the
  page and downloaded) into <store>-regular rows that compare-deals matches by the SAME include/exclude/band
  rules it uses for every other cell. The capture supplies priced candidates ONLY; matching stays PowerShell-side.

  Input format (tab + delimited, one line per commodity):
      <id>\t<name>::<price>|<name>::<price>|...                 (legacy - no product identity)
      <id>\t<name>::<price>::<url>|<name>::<price>::<url>|...   (preferred - carries the product URL)

  CAPTURE THE URL. THE PRICE CAME FROM A PRODUCT CARD THAT HAD ONE.
  The capture reads product cards in a browser - every one of them an <a href> to the product - and the old
  format kept only the name and price, discarding the href. So the row knew its price but not which product it
  priced, and a SEPARATE pass had to search the store to re-find it just to build a link. Two pipelines for one
  fact, and they drifted: the board published "Hy Vee Almondmilk" while its link opened "Blue Diamond Almond
  Breeze"; storage-bags was crowned CHEAPEST at $0.04/each advertising Ziploc 105ct while its link opened That's
  Smart 12ct at $0.099. A price and its link are the SAME FACT and must travel together.
  Both formats parse, so old capture files still import - but a capture that omits the URL leaves its rows
  unlinkable, and the tile ends up showing a price with no "See item". Emit the third field.
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

# READ THE CAPTURE AS UTF-8, AND REPAIR ANYTHING ALREADY MANGLED UPSTREAM.
# A browser Blob download is UTF-8; PowerShell 5.1's Get-Content defaults to the system ANSI codepage
# (Windows-1252 here), so a bare read corrupts every non-ASCII byte and then the row is SAVED that way - the
# damage is baked into the bytes, so reading correctly later does not undo it. That shipped 16 mangled board
# rows on 2026-07-29, 6 of them CROWNS ("Member(junk)s Mark Wildflower Pure Premium Honey" was the first thing
# a shopper read on the honey row). capture-lib.ps1 fixed the four live builders; these four batch importers
# were missed, so the next staples expansion would have re-introduced it.
# Measured on the staged batch files: walmart 50 of 50 lines corrupted by the default read, bakers 40 of 50,
# aldi 2 of 49, fareway 2 of 50. Walmart hits EVERY line because its unit price carries a cent glyph - so the
# corruption lands in the PRICE field, not just the name.
# Repair-Mojibake is applied per LINE rather than per parsed name: it is a no-op on clean text (it fires only
# on a mojibake signature that round-trips through a THROWING UTF-8 decoder), so this is uniform across all
# four importers and cannot damage good data.
. (Join-Path $PSScriptRoot 'capture-lib.ps1')
$lines = @(Get-Content (Join-Path $root $Raw) -Encoding UTF8) | ForEach-Object { Repair-Mojibake $_ }
$rows=New-Object System.Collections.ArrayList
$seen=@{}; $noSize=0; $withUrl=0; $noUrl=0
foreach($ln in $lines){
  if(-not ($ln -match "`t")){ continue }
  $parts=$ln -split "`t",2
  $prodStr=[string]$parts[1]
  foreach($p in ($prodStr -split '\|')){
    # Split on '::' from the RIGHT so a name containing '::' cannot shift the fields. 2 parts = legacy
    # name::price; 3 = name::price::url. Never index from the left here: the name is the untrusted field.
    $seg = $p -split '::'
    if($seg.Count -lt 2){ continue }
    $url = ''
    if($seg.Count -ge 3){
      $url = ([string]$seg[-1]).Trim()
      $priceRaw = [string]$seg[-2]
      $nm = ($seg[0..($seg.Count-3)] -join '::')
    } else {
      $priceRaw = [string]$seg[-1]
      $nm = ($seg[0..($seg.Count-2)] -join '::')
    }
    $nm=($nm.Trim() -replace '\s+title\s*$','' -replace '\s+NET\s+WT\s*$','').Trim()
    $price=0.0; [void][double]::TryParse(($priceRaw -replace '[^0-9.]',''),[ref]$price)
    if($price -le 0 -or -not $nm){ continue }
    # A URL must be a real absolute http(s) link or we do not record one. A relative path or a fragment is not
    # an identity, and a half-built URL is how 4 dead links nearly shipped.
    if($url -and ($url -notmatch '^https?://')){ $url = '' }
    $size=Parse-Size $nm
    if(-not $size){ $noSize++; continue }
    $key=($nm+'|'+$size).ToLower(); if($seen.ContainsKey($key)){ continue }; $seen[$key]=$true
    $row = [ordered]@{ store=$Store; item=$nm; ad_price=('$'+$price); size=$size; regular=$price; current_price=$price; source_ad=$SourceLabel; as_of=$today }
    if($url){ $row['link_url'] = $url; $withUrl++ } else { $noUrl++ }
    [void]$rows.Add($row)
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
# Say out loud how many rows arrived WITHOUT a product URL. Those rows can be priced but never linked, so the
# tile will show a price with no "See item" - and a silent count here is how that became normal.
Write-Output ("  rows carrying a product URL : $withUrl")
if ($noUrl -gt 0) {
  Write-Output ("  rows with NO product URL    : $noUrl   <- these can be priced but NOT linked. The capture is")
  Write-Output ("     dropping the href off product cards it is already reading. Emit <name>::<price>::<url>.")
}
