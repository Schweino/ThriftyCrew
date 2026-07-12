$ProgressPreference='SilentlyContinue'
# Merge weekly resolver outputs (store-*-urls.json) into the durable product-urls.json (accumulates).
# Drop your resolver output files into out\url-inputs\ named store-<store>-urls.json (or ...2, ...3 for
# extra passes). Store is inferred from the filename via $storeOf below. Idempotent; safe to re-run.
$g = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }   # repo-relative
$dir=Join-Path $g "out\url-inputs"
if(-not (Test-Path $dir)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }
# commodity labels (metadata only) from the current comparison + recipe board, if present
$cmap=@{}
$cmpF=(Get-ChildItem (Join-Path $g 'out\comparison-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
foreach($f in @($cmpF)){ if($f){ $c=(Get-Content $f.FullName -Raw|ConvertFrom-Json).comparison; foreach($it in $c){ $cmap[[string]$it.id]=[string]$it.commodity } } }
$riF=Join-Path $g 'out\recipe-board.json'
if(Test-Path $riF){ $c=(Get-Content $riF -Raw|ConvertFrom-Json).comparison; foreach($it in $c){ if(-not $cmap.ContainsKey([string]$it.id)){ $cmap[[string]$it.id]=[string]$it.commodity } } }
# store inferred from filename: store-<key>-... or store-<key>N-...
$storeKey=@{ walmart="Walmart"; sams="Sam's Club"; ff="Family Fare"; familyfare="Family Fare"; hyvee="Hy-Vee"; bakers="Baker's"; aldi="Aldi" }
function StoreOf($fn){ $m=[regex]::Match($fn,'^store-([a-z]+?)[0-9]*-urls\.json$'); if($m.Success -and $storeKey.ContainsKey($m.Groups[1].Value)){ return $storeKey[$m.Groups[1].Value] }; return $null }
$fileStore=@{}
foreach($f in (Get-ChildItem (Join-Path $dir 'store-*-urls.json') -ErrorAction SilentlyContinue)){ $s=StoreOf $f.Name; if($s){ $fileStore[$f.Name]=$s } }
$outFile=Join-Path $g "product-urls.json"
# load existing (accumulate)
$items=@{}
if(Test-Path $outFile){ $pd=Get-Content $outFile -Raw|ConvertFrom-Json; foreach($p in $pd.items.PSObject.Properties){ $h=@{}; foreach($sp in $p.Value.PSObject.Properties){ $h[[string]$sp.Name]=$sp.Value }; $items[[string]$p.Name]=$h } }
$added=0; $storesSeen=@{}
# Process base file first, then numbered passes (store-hyvee -> store-hyvee2 -> store-hyvee3) so a later
# correction file supersedes the original link for the same id+store. Sort by (store-key, numeric-suffix);
# a plain Sort-Object is culture-aware and IGNORES the hyphen, which wrongly puts the base file LAST.
$ordered = $fileStore.Keys | Sort-Object { $m=[regex]::Match($_,'^store-([a-z]+?)([0-9]*)-urls\.json$'); ('{0}_{1:D3}' -f $m.Groups[1].Value, [int]('0'+$m.Groups[2].Value)) }
foreach($fn in $ordered){
  $path=Join-Path $dir $fn
  if(-not (Test-Path $path)){ continue }
  $store=$fileStore[$fn]
  $parsed = ConvertFrom-Json (Get-Content $path -Raw)
  $rows=@($parsed)
  foreach($r in $rows){
    if(-not $r.url){ continue }
    $id=[string]$r.id
    if(-not $items.ContainsKey($id)){ $items[$id]=@{} }
    # normalize price to a NUMBER (resolver inputs use "$2.29" strings; store numeric so every consumer -
    # audit-links / resolve-worklist / audit-name-drift LinkPerUnit - can cast it without a $-sign crash)
    $pnum = $r.price; if ($r.price -is [string]) { $tmp=0.0; if ([double]::TryParse((([string]$r.price) -replace '[^0-9.]',''), [ref]$tmp)) { $pnum = $tmp } }
    $items[$id][$store]=[ordered]@{ url=[string]$r.url; price=$pnum; size=[string]$r.size; name=[string]$r.name }
    $added++; $storesSeen[$store]=$true
  }
}
# build output object
$itemsObj=[ordered]@{}
foreach($id in ($items.Keys|Sort-Object)){
  $entry=[ordered]@{ commodity = $(if($cmap.ContainsKey($id)){$cmap[$id]}else{$id}) }
  foreach($st in ($items[$id].Keys|Sort-Object)){ $entry[$st]=$items[$id][$st] }
  $itemsObj[$id]=$entry
}
$out=[ordered]@{ readme="Durable per-store direct product URLs + verified price for the Omaha grocery prices page. Keyed by commodity id -> store -> {url,price,size,name}. Survives weekly regeneration; build-deals-page.ps1 renders a 'See item' link per chip."; updated=(Get-Date -Format 'yyyy-MM-dd'); items=$itemsObj }
$out | ConvertTo-Json -Depth 6 | Set-Content $outFile -Encoding UTF8
Write-Output ("merged "+$added+" url entries across stores: "+(($storesSeen.Keys|Sort-Object) -join ', '))
Write-Output ("product-urls.json now covers "+$itemsObj.Count+" items")
# coverage per store
$cov=[ordered]@{}
foreach($id in $itemsObj.Keys){ foreach($k in $itemsObj[$id].Keys){ if($k -ne 'commodity'){ if(-not $cov.Contains($k)){$cov[$k]=0}; $cov[$k]++ } } }
$cov.GetEnumerator()|ForEach-Object{ Write-Output ("  {0,-14} {1}" -f $_.Key,$_.Value) }