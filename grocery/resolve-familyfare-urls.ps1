<#
  resolve-familyfare-urls.ps1 - Batch-resolve Family Fare product URLs + verified prices via the Freshop API
  (store 6401 Omaha), for every id in the Family Fare section of out\url-worklist.json.
  For each commodity: query the Freshop API with the commodity's canonical search term, keep only products
  whose name matches the commodity's include/exclude rules (reuses commodities.json + recipe-commodities.json
  so we never grab a wrong product like a frozen/organic/flavored variant), compute per-unit for the
  commodity's unit, and pick the CHEAPEST valid match. Writes out\url-inputs\store-ff-urls.json (merge format)
  plus out\ff-notcarry.json for commodities with no valid match (candidates for the "Does not carry" cell).
#>
param([string]$OutDir = "")
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage; $ProgressPreference='SilentlyContinue'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

$wl = Read-JsonFile (Join-Path $OutDir 'url-worklist.json')
$ff = @($wl.stores.'Family Fare')
. (Join-Path $root 'search-terms-lib.ps1')
$terms = (Read-JsonFile (Join-Path $root 'commodity-search.json')).terms

# The staple board's global exclude is hardcoded in compare-deals.ps1 (staples are never a beverage/candy/
# prepared form); the recipe board relaxes juice/sauce/canned/frozen (recipe items legitimately are those)
# and carries its own global_exclude in recipe-commodities.json. Apply the RIGHT one per id's board.
$STAPLE_GEX = @('drink\s*mix','kool[\s-]?aid','probiotic','kombucha','\bdip\b','\bsauce\b','wrapped','\bbake\b','\bbaked\b','seasoned','marinated','stuffed','\bkit\b','flavored','\bsoup\b','helper','lunchable','smoothie','\bpudding\b','ice\s*cream','\bcreamer\b','\bfrozen\b','\bcanned\b','breaded','\bsnack\b','\bmeal\b','casserole','\bwrap\b','poppers','muffin','pretzel','filled','strudel','\bcake\b','drinkable','(?<!orange\s)\bjuice\b','\bsoda\b','sparkling','seltzer','\bwater\b','energy\s*drink','sports\s*drink','tonic','lemonade','cocktail','pop[\s-]?tart','pastr','toaster','\btart\b','cereal','granola\s*bar','fruit\s*snack','\bgum\b')
# rules: id -> @{include;exclude;unit;gex}   gex = the global-exclude list for that id's board
$rules = @{}
$sdoc = Read-JsonFile (Join-Path $root 'commodities.json')
$slist = if ($sdoc.PSObject.Properties['commodities']) { $sdoc.commodities } else { $sdoc }
foreach ($c in $slist) { $rules[[string]$c.id] = @{ include=@($c.include); exclude=@($c.exclude); unit=[string]$c.unit; gex=$STAPLE_GEX } }
$rdoc = Read-JsonFile (Join-Path $root 'recipe-commodities.json')
$rgex = @($rdoc.global_exclude)
foreach ($c in $rdoc.commodities) { if (-not $rules.ContainsKey([string]$c.id)) { $rules[[string]$c.id] = @{ include=@($c.include); exclude=@($c.exclude); unit=[string]$c.unit; gex=$rgex } } }

function PerUnit([string]$size, [string]$unit, [double]$price) {
  if ($price -le 0) { return $null }
  $s = ([string]$size).ToLower().Trim()
  $m = [regex]::Match($s, '([0-9]+(?:\.[0-9]+)?)'); $num = if ($m.Success) { [double]$m.Groups[1].Value } else { 1.0 }
  if ($num -le 0) { $num = 1.0 }
  switch ($unit) {
    'lb'   { if ($s -match 'lb|pound') { return $price/$num }; if ($s -match 'oz') { return $price/($num/16.0) }; if ($s -match '^\s*(ea|each|ct|count)') { return $price }; return $price }
    'oz'   { if ($s -match 'gal') { return $price/(128.0*$num) }; if ($s -match 'lb|pound') { return $price/(16.0*$num) }; if ($s -match 'fl\s*oz|floz|oz') { return $price/$num }; if ($s -match 'qt|quart') { return $price/(32.0*$num) }; if ($s -match 'pt|pint') { return $price/(16.0*$num) }; return $null }
    'each' { if ($s -match 'lb|pound') { return $null }; return $price/$num }
    'gallon' { if ($s -match 'gal') { return $price/$num }; if ($s -match 'fl\s*oz|floz|oz') { return $price/($num/128.0) }; if ($s -match 'qt|quart') { return $price/($num/4.0) }; return $price }
    'dozen'  { if ($s -match 'doz') { return $price/$num }; if ($s -match 'ct|count|ea|each') { return $price/($num/12.0) }; return $price }
    default { return $price/$num }
  }
}
function MatchesRules($name, $id) {
  $n = ([string]$name).ToLower()
  if (-not $rules.ContainsKey($id)) { return $true }
  $r = $rules[$id]
  foreach ($g in $r.gex) { if ($g -and $n -match $g) { return $false } }      # board-appropriate global exclude first
  $hit = $false; foreach ($inc in $r.include) { if ($inc -and $n -match $inc) { $hit=$true; break } }
  if ($r.include.Count -gt 0 -and -not $hit) { return $false }
  foreach ($exc in $r.exclude) { if ($exc -and $n -match $exc) { return $false } }
  return $true
}

$rows = New-Object System.Collections.Generic.List[object]
$notCarry = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($cell in $ff) {
  $i++
  $id = [string]$cell.id
  $unit = if ($rules.ContainsKey($id)) { $rules[$id].unit } else { [string]$cell.unit }
  # clean generic query beats the over-specific stored product name (which returns few/no API hits)
  # Get-PrimarySearchTerm: [string]$terms.$id JOINS a multi-term commodity into one dead search string.
  $q = if ($terms.PSObject.Properties[$id]) { Get-PrimarySearchTerm $terms $id } else { $id -replace '-',' ' }
  $api = 'https://api.freshop.ncrcloud.com/1/products?app_key=family_fare&store_id=6401&limit=25&q=' + [uri]::EscapeDataString($q)
  $best = $null
  try {
    $resp = Invoke-WebRequest -Uri $api -UseBasicParsing -TimeoutSec 20 -Headers @{'User-Agent'='Mozilla/5.0';'Accept'='application/json'}
    $items = @(($resp.Content | ConvertFrom-Json).items)
    foreach ($p in $items) {
      $nm = [string]$p.name
      if (-not (MatchesRules $nm $id)) { continue }
      $price = 0.0; if ($p.base_price) { [void][double]::TryParse(([string]$p.base_price), [ref]$price) }
      if ($price -le 0) { continue }
      $sz = [string]$p.size; if (-not $sz) { $sz = '' }
      $pu = PerUnit $sz $unit $price
      if ($null -eq $pu -or $pu -le 0) { continue }
      if ($null -eq $best -or $pu -lt $best.pu) {
        $best = @{ pu=$pu; url=[string]$p.canonical_url; price=$price; size=$sz; name=$nm }
      }
    }
  } catch { }
  Start-Sleep -Milliseconds 350
  if ($best -and $best.url) {
    $rows.Add([pscustomobject]@{ id=$id; url=$best.url; price=('$'+('{0:0.00}' -f $best.price)); size=$best.size; name=$best.name; per_unit=[math]::Round($best.pu,4) })
    Write-Output ("OK   {0,-26} `${1,-6} {2,-8} {3}" -f $id, ('{0:0.00}' -f $best.price), $best.size, $best.name)
  } else {
    $notCarry.Add([pscustomobject]@{ id=$id; store='Family Fare'; term=$q })
    Write-Output ("MISS {0,-26} no valid match (query: {1})" -f $id, $q)
  }
}
$dir = Join-Path $OutDir 'url-inputs'; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
($rows | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $dir 'store-ff-urls.json') -Encoding UTF8
($notCarry | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $OutDir 'ff-notcarry.json') -Encoding UTF8
Write-Output ("---- resolved {0} / {1} Family Fare cells ; {2} no-match" -f $rows.Count, $ff.Count, $notCarry.Count)
