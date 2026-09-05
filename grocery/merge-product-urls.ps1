# Merge weekly resolver outputs (store-*-urls.json) into the durable product-urls.json (accumulates).
# Drop your resolver output files into out\url-inputs\ named store-<store>-urls.json (or ...2, ...3 for
# extra passes). Store is inferred from the filename via $storeOf below. Idempotent; safe to re-run.
#
# CONSUME-ONCE (added 2026-08-01, after this script re-broke 36 Fareway links)
# --------------------------------------------------------------------------
# This script used to merge EVERY store-*-urls.json sitting in url-inputs on EVERY run, and never
# removed them. So a capture merged days ago got REPLAYED forever, overwriting links that had since been
# corrected - it silently corrupted ~226 links on 2026-07-14, and on 2026-08-01 a one-day-old Fareway
# file replayed over 36 links that the heal chain had already fixed. Note what an age filter alone would
# have done there: NOTHING. The file was fresh. The defect is REPLAY, not age, so the primary defense is
# ARCHIVING each file the moment it is consumed - a file that is gone cannot resurrect anything.
#
# The replay also proved a subtler point worth keeping: it overwrote the `size` field ("100 ct" -> "each")
# while leaving `url` byte-identical, and the guard reads `size` to pick the basis. A diff that compares
# only URLs reports "nothing changed" on a board that is now wrong in four cells. Compare whole records.
#
#   -MaxAgeDays N   refuse inputs older than N days (belt-and-braces for hand-dropped old captures)
#   -AllowStale     merge them anyway (a deliberate replay, e.g. restoring from url-inputs-archive)
#   -NoArchive      leave consumed files in place (ONLY for debugging; re-enables the replay bug)
#   -SelfTest       sandbox test: fresh file is consumed AND archived; stale file is refused
param(
  [string]$Root = '',
  [int]$MaxAgeDays = 10,
  [switch]$AllowStale,
  [switch]$NoArchive,
  [switch]$SelfTest
)
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$ProgressPreference='SilentlyContinue'
$g = if ($Root) { $Root } elseif ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }   # repo-relative
if ($SelfTest) {
  $sb = Join-Path ([System.IO.Path]::GetTempPath()) ('mpu-selftest-' + [guid]::NewGuid().ToString('N').Substring(0,8))
  New-Item -ItemType Directory -Force -Path (Join-Path $sb 'out\url-inputs') | Out-Null
  $fresh = Join-Path $sb 'out\url-inputs\store-fareway-urls.json'
  $stale = Join-Path $sb 'out\url-inputs\store-aldi-urls.json'
  '[{"id":"turkey-breast","url":"https://x/fresh","price":"$2.99","size":"3 lb","name":"Fresh Row"}]' | Set-Content $fresh -Encoding UTF8
  '[{"id":"turkey-breast","url":"https://x/stale","price":"$9.99","size":"each","name":"Stale Row"}]' | Set-Content $stale -Encoding UTF8
  (Get-Item $stale).LastWriteTime = (Get-Date).AddDays(-40)
  & $PSCommandPath -Root $sb -MaxAgeDays 10 *>&1 | Out-Null
  $res = Read-JsonFile (Join-Path $sb 'product-urls.json')
  $fail = @()
  $tb = $res.items.'turkey-breast'
  if (-not $tb -or [string]$tb.Fareway.url -ne 'https://x/fresh') { $fail += 'FRESH input was not merged' }
  if ($tb -and ($tb.PSObject.Properties.Name -contains 'Aldi')) { $fail += 'STALE input (40 days old) was merged - the age refusal did not fire' }
  # the must-fire fixture of the founding bug: consumed files must be GONE, or the next run replays them
  if (Test-Path $fresh) { $fail += 'consumed input was NOT archived - replay bug is live again' }
  if (-not (Test-Path (Join-Path $sb 'out\url-inputs-archive'))) { $fail += 'archive directory was never created' }
  if (-not (Test-Path $stale)) { $fail += 'REFUSED input was archived - a refused file must stay put for review' }
  # size must survive verbatim: the field whose silent overwrite made a URL-only diff look clean
  if ($tb -and [string]$tb.Fareway.size -ne '3 lb') { $fail += ("size field corrupted: got '" + [string]$tb.Fareway.size + "'") }
  Remove-Item $sb -Recurse -Force -ErrorAction SilentlyContinue
  if ($fail.Count) { $fail | ForEach-Object { Write-Output ("  SELFTEST FAIL: $_") }; Write-Output 'merge-product-urls SELFTEST: FAILED'; exit 2 }
  Write-Output 'merge-product-urls SELFTEST: 6/6 pass (fresh merged, stale refused, consumed archived, refused kept, size verbatim)'
  exit 0
}
$dir=Join-Path $g "out\url-inputs"
if(-not (Test-Path $dir)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }
# commodity labels (metadata only) from the current comparison + recipe board, if present
$cmap=@{}
$cmpF=(Get-ChildItem (Join-Path $g 'out\comparison-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
foreach($f in @($cmpF)){ if($f){ $c=(Read-JsonFile $f.FullName).comparison; foreach($it in $c){ $cmap[[string]$it.id]=[string]$it.commodity } } }
$riF=Join-Path $g 'out\recipe-board.json'
if(Test-Path $riF){ $c=(Read-JsonFile $riF).comparison; foreach($it in $c){ if(-not $cmap.ContainsKey([string]$it.id)){ $cmap[[string]$it.id]=[string]$it.commodity } } }
# store inferred from filename: store-<key>-... or store-<key>N-...
$storeKey=@{ walmart="Walmart"; sams="Sam's Club"; ff="Family Fare"; familyfare="Family Fare"; hyvee="Hy-Vee"; bakers="Baker's"; aldi="Aldi"; fareway="Fareway" }
function StoreOf($fn){ $m=[regex]::Match($fn,'^store-([a-z]+?)[0-9]*-urls\.json$'); if($m.Success -and $storeKey.ContainsKey($m.Groups[1].Value)){ return $storeKey[$m.Groups[1].Value] }; return $null }
$fileStore=@{}; $refused=@()
foreach($f in (Get-ChildItem (Join-Path $dir 'store-*-urls.json') -ErrorAction SilentlyContinue)){
  $s=StoreOf $f.Name; if(-not $s){ continue }
  $ageDays=[math]::Floor(((Get-Date) - $f.LastWriteTime).TotalDays)
  if($ageDays -gt $MaxAgeDays -and -not $AllowStale){ $refused += ("{0} ({1} days old)" -f $f.Name,$ageDays); continue }
  $fileStore[$f.Name]=$s
}
if($refused.Count){
  Write-Output ("REFUSED {0} stale input(s) (older than {1} days). Re-run with -AllowStale to merge anyway:" -f $refused.Count,$MaxAgeDays)
  $refused | ForEach-Object { Write-Output ("    " + $_) }
}
$outFile=Join-Path $g "product-urls.json"
# load existing (accumulate)
$items=@{}
if(Test-Path $outFile){ $pd=Read-JsonFile $outFile; foreach($p in $pd.items.PSObject.Properties){ $h=@{}; foreach($sp in $p.Value.PSObject.Properties){ $h[[string]$sp.Name]=$sp.Value }; $items[[string]$p.Name]=$h } }
$added=0; $storesSeen=@{}
# Process base file first, then numbered passes (store-hyvee -> store-hyvee2 -> store-hyvee3) so a later
# correction file supersedes the original link for the same id+store. Sort by (store-key, numeric-suffix);
# a plain Sort-Object is culture-aware and IGNORES the hyphen, which wrongly puts the base file LAST.
$ordered = $fileStore.Keys | Sort-Object { $m=[regex]::Match($_,'^store-([a-z]+?)([0-9]*)-urls\.json$'); ('{0}_{1:D3}' -f $m.Groups[1].Value, [int]('0'+$m.Groups[2].Value)) }
foreach($fn in $ordered){
  $path=Join-Path $dir $fn
  if(-not (Test-Path $path)){ continue }
  $store=$fileStore[$fn]
  $parsed = Read-JsonFile $path
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
# CONSUME-ONCE: archive every file we just merged, so the next run cannot replay it over links that have
# since been corrected. Refused (stale) files are deliberately LEFT IN PLACE so they stay visible for review.
if(-not $NoArchive -and $ordered){
  $arch=Join-Path $g 'out\url-inputs-archive'
  if(-not (Test-Path $arch)){ New-Item -ItemType Directory -Force -Path $arch | Out-Null }
  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
  foreach($fn in $ordered){
    $src=Join-Path $dir $fn
    if(Test-Path $src){ Move-Item $src (Join-Path $arch ($stamp+'-'+$fn)) -Force }
  }
  Write-Output ("archived {0} consumed input file(s) to out\url-inputs-archive (consume-once: they can never replay)" -f @($ordered).Count)
}
Write-Output ("merged "+$added+" url entries across stores: "+(($storesSeen.Keys|Sort-Object) -join ', '))
Write-Output ("product-urls.json now covers "+$itemsObj.Count+" items")
# coverage per store
$cov=[ordered]@{}
foreach($id in $itemsObj.Keys){ foreach($k in $itemsObj[$id].Keys){ if($k -ne 'commodity'){ if(-not $cov.Contains($k)){$cov[$k]=0}; $cov[$k]++ } } }
$cov.GetEnumerator()|ForEach-Object{ Write-Output ("  {0,-14} {1}" -f $_.Key,$_.Value) }