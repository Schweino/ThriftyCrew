<#
  fill-newitems-ff.ps1 - fill Family Fare gaps for the 27 new board commodities via the Freshop API.

  SAFETY: we only append rows that match the TARGET commodity's own include/exclude AND fall inside its
  per-unit band. We never bulk-dump raw search results into the regular file, because an unrelated product
  (e.g. a pasta sauce returned by a "tomato sauce" search) could get claimed by a DIFFERENT commodity and
  silently change an existing board cell.
#>
param([string[]]$Only = @())
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$today = '2026-07-14'

$TERMS = @{
  'floor-cleaner'     = @('floor cleaner','pine sol','fabuloso')
  'drain-cleaner'     = @('drain cleaner','drano','liquid plumr')
  'oven-cleaner'      = @('oven cleaner','easy off')
  'shower-cleaner'    = @('shower cleaner','scrubbing bubbles','bathroom cleaner')
  'furniture-polish'  = @('furniture polish','pledge','dusting spray')
  'insect-spray'      = @('raid ant roach','insect killer spray','bug spray')
  'cornstarch'        = @('corn starch','cornstarch')
  'bread-crumbs'      = @('bread crumbs','panko')
  'paprika'           = @('paprika')
  'dried-oregano'     = @('oregano')
  'dried-parsley'     = @('parsley flakes','parsley')
  'ground-cinnamon'   = @('ground cinnamon')
  'ground-turmeric'   = @('turmeric')
  'red-pepper-flakes' = @('crushed red pepper','red pepper flakes')
  'garlic-powder'     = @('garlic powder')
  'onion-powder'      = @('onion powder')
  'chili-powder'      = @('chili powder')
  'ground-cumin'      = @('ground cumin','cumin')
  'italian-seasoning' = @('italian seasoning')
  'chickpeas'         = @('garbanzo beans','chick peas')
  'kidney-beans'      = @('kidney beans')
  'crushed-tomatoes'  = @('crushed tomatoes')
  'tomato-paste'      = @('tomato paste')
  'tomato-sauce'      = @('tomato sauce')
  'soy-sauce'         = @('soy sauce')
  'white-vinegar'     = @('distilled white vinegar','white vinegar')
  'lemon-juice'       = @('lemon juice')
}

$commods = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
$UA = @{ 'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/125 Safari/537.36'; 'Accept'='application/json' }
$ak='family_fare'; $sid='6401'; $base='https://api.freshop.ncrcloud.com/1'

function Get-Items($term) {
  $uri = "$base/products?app_key=$ak&store_id=$sid&q=" + [uri]::EscapeDataString($term) + "&limit=60&fields=name,brand,size,price,base_price"
  for ($t=0; $t -lt 4; $t++) {
    try { $items = @((Invoke-RestMethod -Uri $uri -Headers $UA -TimeoutSec 25).items); if ($items.Count -gt 0) { return $items } } catch {}
    Start-Sleep -Milliseconds (700 + 500*$t)
  }
  return @()
}
function Parse-Qty([string]$size,[string]$unit) {
  if (-not $size) { return 0 }
  $m = [regex]::Match($size.ToLower(),'([\d]+(?:\.[\d]+)?)\s*(fl\s?oz|floz|oz|lbs?|pound|g|kg|ml|l|liter|qt|gal|ct)')
  if (-not $m.Success) { return 0 }
  $n = [double]$m.Groups[1].Value; $u = $m.Groups[2].Value -replace '\s',''
  switch ($unit) {
    'oz'   { switch -regex ($u) { '^oz$' {return $n} '^(lbs?|pound)$' {return $n*16} '^g$' {return $n*0.035274} '^kg$' {return $n*35.274} default {return 0} } }
    'floz' { switch -regex ($u) { '^(floz|foz)$' {return $n} '^oz$' {return $n} '^(l|liter)$' {return $n*33.814} '^ml$' {return $n*0.033814} '^qt$' {return $n*32} '^gal$' {return $n*128} default {return 0} } }
    'lb'   { switch -regex ($u) { '^(lbs?|pound)$' {return $n} '^oz$' {return $n/16} default {return 0} } }
  }
  return 0
}

$rows = New-Object System.Collections.ArrayList
foreach ($id in $TERMS.Keys) {
  if ($Only.Count -and ($Only -notcontains $id)) { continue }
  $cm = $commods | Where-Object { $_.id -eq $id }
  if (-not $cm) { Write-Output ("  ?? no commodity $id"); continue }

  $best = $null
  foreach ($term in $TERMS[$id]) {
    foreach ($it in (Get-Items $term)) {
      $name = [string]$it.name
      if (-not $name) { continue }
      $inc = $false; foreach ($i in $cm.include) { if ($name -match $i) { $inc = $true; break } }
      if (-not $inc) { continue }
      $bad = $false; foreach ($e in $cm.exclude) { if ($name -match $e) { $bad = $true; break } }
      if ($bad) { continue }
      $val = if ($it.base_price) { [double]$it.base_price } elseif ($it.price) { [double](([string]$it.price) -replace '[^\d.]','') } else { 0 }
      if ($val -le 0) { continue }
      $qty = Parse-Qty ([string]$it.size) ([string]$cm.unit)
      if ($qty -le 0) { continue }
      $per = $val / $qty
      if ($per -lt $cm.band_min -or $per -gt $cm.band_max) { continue }   # band = the sanity gate
      if (-not $best -or $per -lt $best.per) { $best = @{ name=$name; price=$val; size=[string]$it.size; per=$per } }
    }
    Start-Sleep -Milliseconds 400
  }
  if ($best) {
    [void]$rows.Add([ordered]@{ store='Family Fare'; item=$best.name; ad_price=('$' + $best.price.ToString('0.00')); size=$best.size; regular=$null; source_ad='Freshop base_price (store 6401) - new-item fill' })
    Write-Output ("  {0,-20} {1,-46} {2} {3}  (per {4})" -f $id, $best.name, ('$'+$best.price.ToString('0.00')), $best.size, [math]::Round($best.per,4))
  } else {
    Write-Output ("  {0,-20} NO MATCH IN BAND (left missing, not guessed)" -f $id)
  }
}

if ($rows.Count) {
  $regDir = Join-Path $root 'out\regular'
  $f = Get-ChildItem (Join-Path $regDir 'family-fare-regular-*.json') | Sort-Object Name -Descending | Select-Object -First 1
  $doc = Get-Content $f.FullName -Raw | ConvertFrom-Json
  $all = New-Object System.Collections.ArrayList
  foreach ($d in $doc.deals) { [void]$all.Add($d) }
  $have = @($doc.deals | ForEach-Object { [string]$_.item })
  $added = 0
  foreach ($r in $rows) { if ($have -notcontains $r.item) { [void]$all.Add($r); $added++ } }
  $doc.deals = $all.ToArray()
  ($doc | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $regDir ('family-fare-regular-' + $today + '.json')) -Encoding UTF8
  Write-Output ""
  Write-Output ("Family Fare regular file: +$added rows -> " + @($doc.deals).Count + " total")
}
