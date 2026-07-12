<#
  export-feed.ps1 - Builds smp-feed.json, the single public price feed the website fetches at view time.

  This is the "database" the pages read from: instead of baking prices into 113 published posts, every
  page/widget fetches this one file and shows THIS WEEK's numbers, falling back to its own baked-in
  baseline if the fetch ever fails. When a sale moves a price, this file updates and every page is current
  on its next load - no republishing.

  Sources (all already produced by the daily pipeline; no new price logic here):
    - out\recipe-costs.json      (recipe week-costs, from top5-weekly.ps1)
    - out\recipe-board.json      (recipe-ingredient board, sale-overlaid)
    - out\comparison-*.json      (weekly staples board)
    - ..\meal-prep\recipes-db.json (base servings)

  Output: out\smp-feed.json  (committed by the workflow; served publicly via Cloudflare Pages).
#>
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$out  = Join-Path $root 'out'
$mp   = Join-Path (Split-Path $root -Parent) 'meal-prep'

# ---- ingredients: cheapest verified price per board commodity id (both boards) ----
# durable product links: id -> store -> url (so the feed can point at the exact cheapest item)
$purl = @{}
try {
  $pd = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items
  foreach ($p in $pd.PSObject.Properties) {
    $m = @{}
    foreach ($sp in $p.Value.PSObject.Properties) { if ($sp.Name -ne 'commodity' -and $sp.Value -and $sp.Value.url) { $m[[string]$sp.Name] = [string]$sp.Value.url } }
    $purl[[string]$p.Name] = $m
  }
} catch {}
# sale windows: id|store -> sale_end, so the feed can carry "sale ends <date>" for the cheapest chip.
# sale-windows.json is gitignored + regenerated daily on both local and cloud (check-ad-cycles runs
# build-sale-windows BEFORE export-feed) - if it is missing we just emit no sale_end fields.
$saleEnd = @{}
try {
  $sw = Get-Content (Join-Path $root 'sale-windows.json') -Raw | ConvertFrom-Json
  $todayS = (Get-Date).ToString('yyyy-MM-dd')
  foreach ($w in $sw.windows) {
    if (-not $w.sale_end) { continue }
    if ([string]$w.sale_end -lt $todayS) { continue }   # expired window: no badge
    $saleEnd[([string]$w.id + '|' + [string]$w.store)] = [string]$w.sale_end
  }
} catch {}

# board-price overrides (same file the page build + audit use): pin an EVERYDAY cell to the verified per-unit
# of the product its link opens, so the PUBLIC feed (CF Worker -> 113 recipe widgets) never serves a stale
# board price either. Sales are never overridden.
$ovr = @{}
$ovrFile = Join-Path $root 'board-price-overrides.json'
if (Test-Path $ovrFile) { try { foreach ($c in (Get-Content $ovrFile -Raw | ConvertFrom-Json).cells) { $k=[string]$c.id; if (-not $ovr.ContainsKey($k)) { $ovr[$k]=@{} }; $ovr[$k][[string]$c.store]=[double]$c.per_unit } } catch {} }

$ing = [ordered]@{}
function AddBoard($rows) {
  foreach ($r in $rows) {
    $id = [string]$r.id
    $lo = $null; $los = ''; $lot = ''; $nStores = 0
    foreach ($s in $r.stores) {
      $p = [double]$s.per_unit
      if (([string]$s.type) -eq 'everyday' -and $ovr.ContainsKey($id) -and $ovr[$id].ContainsKey([string]$s.store)) { $ov=[double]$ovr[$id][[string]$s.store]; if ($ov -gt 0) { $p = $ov } }
      if ($p -gt 0) { $nStores++ }
      if ($p -gt 0 -and ($null -eq $lo -or $p -lt $lo)) { $lo = $p; $los = [string]$s.store; $lot = [string]$s.type }
    }
    if ($null -ne $lo) {
      # weekly board wins ties for a shared id (it carries this week's ad price); don't overwrite it with recipe floor
      if (-not $ing.Contains($id)) {
        $u = if ($purl.ContainsKey($id) -and $purl[$id].ContainsKey($los)) { $purl[$id][$los] } else { '' }
        # n = how many of the 6 stores actually have a price for this ingredient - so the UI never overclaims
        # "checked at 6 stores" for an item only 1-2 stores have been priced at yet (new adds, or an item some
        # stores simply don't carry).
        $row = [ordered]@{ unit=[string]$r.unit; cheapest=[math]::Round($lo,4); store=$los; type=$lot; url=$u; n=$nStores }
        # attach the sale's end date when the winning chip IS the sale and its window is known
        if ($lot -eq 'sale') { $sk = $id + '|' + $los; if ($saleEnd.ContainsKey($sk)) { $row['sale_end'] = $saleEnd[$sk] } }
        $ing[$id] = $row
      }
    }
  }
}
$cmpF = Get-ChildItem (Join-Path $out 'comparison-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
$weekOf = ''
if ($cmpF) { $cdoc = Get-Content $cmpF.FullName -Raw | ConvertFrom-Json; $weekOf = [string]$cdoc.week_of; AddBoard $cdoc.comparison }   # weekly first (wins ties)
$rbF = Join-Path $out 'recipe-board.json'
if (Test-Path $rbF) { AddBoard (Get-Content $rbF -Raw | ConvertFrom-Json).comparison }

# ---- recipes: this week's cost per slug (+ base servings for the scaler) ----
$servings = @{}
try { foreach ($r in (Get-Content (Join-Path $mp 'recipes-db.json') -Raw | ConvertFrom-Json).recipes) { $servings[[string]$r.slug] = [int]$r.servings } } catch {}
$rec = [ordered]@{}
$rcF = Join-Path $out 'recipe-costs.json'
if (Test-Path $rcF) {
  foreach ($c in (Get-Content $rcF -Raw | ConvertFrom-Json).recipes) {
    $slug = [string]$c.slug
    $rec[$slug] = [ordered]@{
      name        = [string]$c.name
      servings    = if ($servings.ContainsKey($slug)) { $servings[$slug] } else { 14 }
      week_cost   = [double]$c.week_cost
      per_serving = [double]$c.per_serving
      calories    = [int]$c.calories
      sale_items  = @($c.sale_items)
    }
  }
}

$feed = [ordered]@{
  generated   = (Get-Date).ToString('s')
  week_of     = $weekOf
  ingredient_count = $ing.Count
  recipe_count     = $rec.Count
  ingredients = $ing
  recipes     = $rec
}
# Write to the repo-root public\ dir - this is the ONLY folder Cloudflare Pages serves, so nothing else
# in the repo is exposed. _headers there sets CORS + cache. Keep a copy in out\ for local inspection.
$json = $feed | ConvertTo-Json -Depth 8
$json | Set-Content (Join-Path $out 'smp-feed.json') -Encoding UTF8
$pub = Join-Path (Split-Path $root -Parent) 'public'
if (-not (Test-Path $pub)) { New-Item -ItemType Directory -Force -Path $pub | Out-Null }
$json | Set-Content (Join-Path $pub 'smp-feed.json') -Encoding UTF8
Write-Output ("smp-feed.json: " + $ing.Count + " ingredients, " + $rec.Count + " recipes, week " + $weekOf + " -> out\ + public\")
