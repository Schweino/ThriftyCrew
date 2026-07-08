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
$ing = [ordered]@{}
function AddBoard($rows) {
  foreach ($r in $rows) {
    $id = [string]$r.id
    $lo = $null; $los = ''; $lot = ''
    foreach ($s in $r.stores) {
      $p = [double]$s.per_unit
      if ($p -gt 0 -and ($null -eq $lo -or $p -lt $lo)) { $lo = $p; $los = [string]$s.store; $lot = [string]$s.type }
    }
    if ($null -ne $lo) {
      # weekly board wins ties for a shared id (it carries this week's ad price); don't overwrite it with recipe floor
      if (-not $ing.Contains($id)) {
        $ing[$id] = [ordered]@{ unit=[string]$r.unit; cheapest=[math]::Round($lo,4); store=$los; type=$lot }
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
