<#
  research-familyfare-everyday.ps1 - keeps Family Fare's EVERYDAY fallback price current for every commodity,
  headless, via the Freshop API. This is what makes "when an item goes OFF sale, fall back to the next cheapest
  item at that store" real for Family Fare: even while a commodity is on SALE, we research its cheapest EVERYDAY
  (base_price) product so the moment the sale ends the board reverts to the true next-cheapest item, not to a
  vanished cell or a stale price. Runs daily in check-ad-cycles (FF is the only fully-API store). Browser stores
  (Aldi/Hy-Vee/Baker's/Walmart/Sam's/Fareway) get the same via the weekly agent + research-worklist.json.

  For each commodity it queries Freshop (store 6401 = Omaha), keeps items matching the commodity's include and
  not its exclude / the global prepared-form list, computes each one's EVERYDAY per-unit from base_price, and
  writes the cheapest as out\regular\family-fare-regular-<date>.json (price_type=everyday). compare-deals then
  auto-loads it and ranks it against the sale, so the cheapest of {sale, everyday} wins - and everyday wins the
  day the sale ends.
#>
param([string]$OutDir = "")
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$asofS = (Get-Date).ToString('yyyy-MM-dd')
$commods = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
$terms = @{}
try { $ts = Get-Content (Join-Path $root 'commodity-search.json') -Raw | ConvertFrom-Json; foreach ($p in $ts.terms.PSObject.Properties) { $terms[$p.Name] = [string]$p.Value } } catch {}
# prepared/different-form terms that are NOT the plain commodity (mirror compare-deals' GLOBAL_EXCLUDE, trimmed)
$GLOBAL = @('\bdip\b','\bsauce\b','wrapped','seasoned','marinated','stuffed','\bkit\b','flavored','\bsoup\b',
  'helper','smoothie','\bpudding\b','ice\s*cream','\bcreamer\b','\bfrozen\b','\bcanned\b','breaded','\bsnack\b',
  '\bmeal\b','casserole','muffin','pretzel','\bcake\b','pop[\s-]?tart','cereal','granola\s*bar','\bjuice\b(?<!orange\s\bjuice)',
  '\bbeer\b','\bwine\b','liquor','organic','\bcooked\b','deli\b','lunch\s*meat','\bnugget','\bpatty\b','patties')

function PU([string]$size, [string]$unit, [double]$price) {
  $s = ([string]$size).ToLower().Trim(); if ($price -le 0) { return $null }
  $q = [regex]::Match($s, '([0-9]+(?:\.[0-9]+)?)\s*(fl\s*oz|floz|oz|lbs?|gallon|gal|ct|count|ea|each|pint|pt|dozen|doz)')
  $n = $null; $u = ''
  if ($q.Success) { $n = [double]$q.Groups[1].Value; $u = ($q.Groups[2].Value -replace '\s','') -replace 'fl','' }
  else { $bu = [regex]::Match($s, '\b(lbs?|gallon|gal|dozen|doz|each|ea|pint|pt)\b'); if ($bu.Success) { $n = 1; $u = $bu.Groups[1].Value } }
  if (-not $n) { return $null }
  $u = $u -replace '^gallon$','gal' -replace '^doz$','dozen' -replace '^pt$','pint' -replace '^lbs$','lb' -replace '^count$','ct' -replace '^ea$','each'
  switch ($unit) {
    'lb'     { if ($u -eq 'lb') { return $price/$n }; if ($u -eq 'oz') { return $price/($n/16) }; return $null }
    'oz'     { if ($u -eq 'oz') { return $price/$n }; if ($u -eq 'lb') { return $price/(16*$n) }; return $null }
    'floz'   { if ($u -match 'oz') { return $price/$n }; if ($u -eq 'gal') { return $price/(128*$n) }; return $null }
    'each'   { if ($u -match '^(ct|each|pint)$') { return $price/$n }; if ($u -eq 'dozen') { return $price/(12*$n) }; $pk=[regex]::Match($s,'([0-9]+)\s*(pk|pack)'); if ($pk.Success) { return $price/[double]$pk.Groups[1].Value }; return $price }
    'dozen'  { if ($u -eq 'dozen') { return $price/$n }; if ($u -eq 'ct') { return $price/($n/12) }; return $null }
    'gallon' { if ($u -eq 'gal') { return $price/$n }; return $null }
  }
  return $null
}

$deals = @()
$ua = 'Mozilla/5.0'; $miss = @()
foreach ($c in $commods) {
  $id = [string]$c.id; $unit = [string]$c.unit
  $term = if ($terms.ContainsKey($id)) { $terms[$id] } else { ($c.label -replace '\s*\([^)]*\)','').Trim() }
  $api = 'https://api.freshop.ncrcloud.com/1/products?app_key=family_fare&store_id=6401&limit=40&fields=name,base_price,size,canonical_url&q=' + [uri]::EscapeDataString($term)
  $best = $null; $bestPU = [double]::MaxValue
  $items = $null
  for ($try = 0; $try -lt 5 -and $null -eq $items; $try++) {
    try { $items = (Invoke-WebRequest -Uri $api -UseBasicParsing -TimeoutSec 25 -Headers @{'User-Agent'=$ua;'Accept'='application/json'}).Content | ConvertFrom-Json } catch { Start-Sleep -Milliseconds (900*($try+1)) }
  }
  if ($null -eq $items) { $miss += "$id (api err)"; continue }
  foreach ($p in $items.items) {
      $nm = [string]$p.name; if (-not $nm) { continue }
      # commodity include / exclude
      $inc = $false; foreach ($rx in $c.include) { if ($nm -imatch $rx) { $inc = $true; break } }; if (-not $inc) { continue }
      $skip = $false; foreach ($rx in $c.exclude) { if ($rx -and $nm -imatch $rx) { $skip = $true; break } }
      if (-not $skip) { foreach ($rx in $GLOBAL) { if ($nm -imatch $rx) { $skip = $true; break } } }
      if ($skip) { continue }
      $bp = 0.0; [void][double]::TryParse((([string]$p.base_price) -replace '[^0-9.]',''), [ref]$bp); if ($bp -le 0) { continue }
      $pu = PU ([string]$p.size) $unit $bp; if ($null -eq $pu -or $pu -le 0) { continue }
      if ($pu -lt $bestPU) { $bestPU = $pu; $best = $p }
    }
  Start-Sleep -Milliseconds 500
  if ($best) { $deals += ,([pscustomobject]@{ id=$id; store='Family Fare'; item=[string]$best.name; ad_price=('$' + [string]$best.base_price); size=[string]$best.size; regular=''; source_ad='FF everyday (Freshop base_price)'; url=[string]$best.canonical_url }) }
  else { $miss += "$id (no everyday match)" }
}
# CARRY FORWARD: a transient Freshop rate-limit must never blank a fallback. For any commodity we did not
# capture today, keep yesterday's entry from the previous FF everyday file (matched by its id tag).
$coveredIds = @($deals | ForEach-Object { [string]$_.id })
$prev = Get-ChildItem (Join-Path $OutDir 'regular\family-fare-regular-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if ($prev) { try { foreach ($d in (Get-Content $prev.FullName -Raw | ConvertFrom-Json).deals) { if ($d.id -and ($coveredIds -notcontains [string]$d.id)) { $deals += ,$d; $coveredIds += [string]$d.id; $miss = @($miss | Where-Object { $_ -notlike ($d.id + ' *') }) } } } catch {} }
$doc = [ordered]@{ store='Family Fare'; price_type='everyday'; source='Freshop base_price (Omaha 6401)'; generated=$asofS; deals=$deals }
$regDir = Join-Path $OutDir 'regular'; New-Item -ItemType Directory -Force -Path $regDir | Out-Null
$doc | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $regDir "family-fare-regular-$asofS.json") -Encoding UTF8
Write-Output ("family-fare-regular-$asofS.json: $($deals.Count) everyday commodities" + $(if ($miss.Count) { " (no everyday: " + ($miss -join ', ') + ")" } else { '' }))
