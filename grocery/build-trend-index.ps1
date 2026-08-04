<#
  build-trend-index.ps1 - Renders out\trend\index.html: a self-contained fragment listing every
  price trend page as a card (label, current cheapest price + store, link to /<id>-price-omaha/),
  grouped by category. Meant to be published manually at /omaha-price-tracker/.

  Same qualifying rule as build-trend-pages.ps1: only commodities with >= $MinWeeks history entries.
  PowerShell 5.1 safe. UTF-8 no BOM output. Fragment only, no <h1>.
#>
param(
  [string]$HistoryFile = '',
  [string]$OutFile = '',
  [int]$MinWeeks = 3
)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($HistoryFile)) { $HistoryFile = Join-Path $here 'price-history.json' }
if ([string]::IsNullOrWhiteSpace($OutFile))     { $OutFile     = Join-Path $here 'out\trend\index.html' }

. (Join-Path $here '..\lib\trend-keep.ps1')   # 2026-08-04: single source for which commodities get a page

$utf8 = New-Object System.Text.UTF8Encoding($false)

function Esc { param([string]$t)
  if ($null -eq $t) { return '' }
  return $t.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;').Replace("'",'&#39;')
}

function Format-Price { param([double]$p)
  $r = [math]::Round($p, 4)
  if ($r -ge 1) { return ('${0:N2}' -f $r) }
  $s = $r.ToString('0.0000', [System.Globalization.CultureInfo]::InvariantCulture)
  $s = $s.TrimEnd('0')
  $parts = $s.Split('.')
  $dec = ''
  if ($parts.Length -gt 1) { $dec = $parts[1] }
  while ($dec.Length -lt 2) { $dec = $dec + '0' }
  return ('$' + $parts[0] + '.' + $dec)
}

function Get-UnitSuffix { param([string]$u)
  switch ($u) {
    'lb'     { return '/lb' }
    'oz'     { return '/oz' }
    'floz'   { return '/fl oz' }
    'each'   { return ' each' }
    'dozen'  { return '/dozen' }
    'gallon' { return '/gallon' }
    default  { return ('/' + $u) }
  }
}

# Board store coverage - keep in lockstep with $storeOrder (build-deals-page.ps1) / the audit store lists.
# Both the count-word and the named list below derive from this one array so the copy can't go stale.
$StoreNames = @('Hy-Vee','Aldi','Family Fare','Fareway',"Baker's","Sam's Club",'Walmart')
$numWords   = @('zero','one','two','three','four','five','six','seven','eight','nine','ten','eleven','twelve')
$StoreWord  = if ($StoreNames.Count -lt $numWords.Count) { $numWords[$StoreNames.Count] } else { [string]$StoreNames.Count }
$escStores  = @($StoreNames | ForEach-Object { Esc $_ })
if ($escStores.Count -gt 1) { $StoreList = ($escStores[0..($escStores.Count - 2)] -join ', ') + ' and ' + $escStores[-1] } else { $StoreList = [string]$escStores[0] }

# category map by commodity id; anything unmapped lands in "More staples"
$catOf = @{
  'chicken-breast'   = 'Meat and protein'
  'chicken-thighs'   = 'Meat and protein'
  'whole-chicken'    = 'Meat and protein'
  'ground-beef-8020' = 'Meat and protein'
  'ground-turkey'    = 'Meat and protein'
  'bacon'            = 'Meat and protein'
  'pork-chops'       = 'Meat and protein'
  'eggs'             = 'Dairy and eggs'
  'milk'             = 'Dairy and eggs'
  'butter'           = 'Dairy and eggs'
  'shredded-cheese'  = 'Dairy and eggs'
  'cream-cheese'     = 'Dairy and eggs'
  'cottage-cheese'   = 'Dairy and eggs'
  'sour-cream'       = 'Dairy and eggs'
  'yogurt'           = 'Dairy and eggs'
  'apples'           = 'Produce'
  'avocados'         = 'Produce'
  'bananas'          = 'Produce'
  'blueberries'      = 'Produce'
  'grapes'           = 'Produce'
  'peaches'          = 'Produce'
  'strawberries'     = 'Produce'
  'watermelon'       = 'Produce'
  'sweet-corn'       = 'Produce'
  'russet-potatoes'  = 'Produce'
  'onions'           = 'Produce'
  'bread'            = 'Pantry and drinks'
  'peanut-butter'    = 'Pantry and drinks'
  'coffee'           = 'Pantry and drinks'
  'orange-juice'     = 'Pantry and drinks'
}
$catOrder = @('Meat and protein', 'Dairy and eggs', 'Produce', 'Pantry and drinks', 'More staples')

if (-not (Test-Path $HistoryFile)) { throw "History file not found: $HistoryFile" }
$data = Get-Content $HistoryFile -Raw | ConvertFrom-Json

# bucket qualifying commodities by category
$buckets = [ordered]@{}
foreach ($cat in $catOrder) { $buckets[$cat] = @() }
$included = 0

foreach ($c in $data.commodities) {
  # 2026-08-04: this hub must list exactly the pages that exist, or it becomes 472 dead links.
  # Same single gate the publisher and the board use. See lib\trend-keep.ps1.
  if (-not (Test-TrendKeep $c.id)) { continue }
  $hist = @($c.history | Sort-Object week_of)
  if ($hist.Count -lt $MinWeeks) { continue }
  $cur = $hist[$hist.Count - 1]
  $cat = 'More staples'
  if ($catOf.ContainsKey($c.id)) { $cat = $catOf[$c.id] }
  $card = New-Object PSObject -Property @{
    id    = [string]$c.id
    label = [string]$c.label
    unit  = [string]$c.unit
    price = [double]$cur.cheapest_price
    store = [string]$cur.cheapest_store
    week  = [string]$cur.week_of
  }
  $buckets[$cat] = @($buckets[$cat]) + $card
  $included++
}

$newestWeek = ''
foreach ($cat in $catOrder) {
  foreach ($card in $buckets[$cat]) { if ($card.week -gt $newestWeek) { $newestWeek = $card.week } }
}
$weekLabel = ''
if ($newestWeek -ne '') {
  $d = [datetime]::ParseExact($newestWeek, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
  $weekLabel = $d.ToString('MMM d, yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
}

# ---------- assemble fragment ----------

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('<div class="tp-wrap">')
[void]$sb.AppendLine(@'
<style>
.tp-wrap{line-height:1.55;margin:0}
.tp-intro{margin:0 0 18px;color:#374151}
.tp-cat{margin:26px 0 10px;font-size:1.15rem;font-weight:700;color:#1f2937}
.tp-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:12px;margin:0 0 6px}
.tp-card{display:block;border:1px solid #e8dfc9;border-radius:12px;padding:14px 16px;background:#faf8f2;text-decoration:none;color:inherit;transition:box-shadow .15s ease}
.tp-card:hover{box-shadow:0 2px 10px rgba(0,0,0,.08)}
.tp-card-label{font-weight:700;color:#1f2937;margin:0 0 4px}
.tp-card-price{font-size:1.35rem;font-weight:800;color:#1f7a4d}
.tp-card-price .tp-unit{font-size:.9rem;font-weight:600;color:#6b7280}
.tp-card-store{font-size:.88rem;color:#6b7280;margin-top:2px}
.tp-card-cta{display:inline-block;margin-top:8px;font-size:.82rem;font-weight:700;color:#b07c1e}
.tp-links{margin:22px 0 10px}
.tp-foot{font-size:.85rem;color:#9ca3af;margin:0}
</style>
'@)
$intro = 'We track the cheapest price for ' + $included + ' Omaha grocery staples every week across ' + $StoreWord + ' stores. Pick an item to see this week&#39;s best price, the tracked record low, and how it has moved week by week.'
if ($weekLabel -ne '') { $intro = $intro + ' Prices below are from the week of ' + (Esc $weekLabel) + '.' }
[void]$sb.AppendLine('<p class="tp-intro">' + $intro + '</p>')

foreach ($cat in $catOrder) {
  $cards = @($buckets[$cat])
  if ($cards.Count -eq 0) { continue }
  $cards = @($cards | Sort-Object label)
  [void]$sb.AppendLine('<div class="tp-cat">' + (Esc $cat) + '</div>')
  [void]$sb.AppendLine('<div class="tp-grid">')
  foreach ($card in $cards) {
    $href = '/' + $card.id + '-price-omaha/'
    [void]$sb.AppendLine('<a class="tp-card" href="' + $href + '">')
    [void]$sb.AppendLine('  <div class="tp-card-label">' + (Esc $card.label) + '</div>')
    [void]$sb.AppendLine('  <div class="tp-card-price">' + (Format-Price $card.price) + '<span class="tp-unit">' + (Esc (Get-UnitSuffix $card.unit)) + '</span></div>')
    [void]$sb.AppendLine('  <div class="tp-card-store">at ' + (Esc $card.store) + ' this week</div>')
    [void]$sb.AppendLine('  <span class="tp-card-cta">See the trend</span>')
    [void]$sb.AppendLine('</a>')
  }
  [void]$sb.AppendLine('</div>')
}

[void]$sb.AppendLine('<p class="tp-links"><a href="/omaha-grocery-prices/?ref=trend">See the full live Omaha price board</a></p>')
[void]$sb.AppendLine('<p class="tp-foot">Tracked weekly across ' + $StoreList + ' in Omaha since June 2026. This page updates every week.</p>')
[void]$sb.Append('</div>')

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
[IO.File]::WriteAllText($OutFile, $sb.ToString(), $utf8)
Write-Host ('Index written: {0} ({1} staples listed)' -f $OutFile, $included) -ForegroundColor Green
