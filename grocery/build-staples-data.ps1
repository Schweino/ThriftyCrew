# build-staples-data.ps1 - emits the embedded dataset for the My Staples watchlist tool.
# Combines: the 29 weekly commodities (commodities.json + categories.json), the recipe-board
# everyday items (recipe-board.json), record lows (price-history.json), trend-page slugs,
# and bakes current feed prices as the offline fallback. Output: staples-data.js
# Splice into my-staples-template.html at //__DATA__ -> C:\Codex\ThriftyCrew\site\tools\my-staples-tool.html
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = 'C:\Codex\ThriftyCrew\grocery'
# prefer the freshly-exported local feed (has the newest schema, e.g. sale_end) over the edge-cached worker copy
$localFeed = "$root\out\smp-feed.json"
if (Test-Path $localFeed) { $raw = (Get-Content $localFeed -Raw).TrimStart([char]0xFEFF) }
else { $raw = (Invoke-WebRequest -Uri "https://feed.thriftycrew.com/smp-feed.json" -UseBasicParsing -TimeoutSec 30).Content.TrimStart([char]0xFEFF) }
$feed = $raw | ConvertFrom-Json
$feedIng = @{}
foreach ($p in $feed.ingredients.PSObject.Properties) { $feedIng[[string]$p.Name] = $p.Value }

$cats = (Read-JsonFile "$root\categories.json").categories
$catOf = @{}
foreach ($c in $cats) { foreach ($cid in $c.commodities) { $catOf[[string]$cid] = [string]$c.label } }
$comms = Read-JsonFile "$root\commodities.json"

# records (only the weekly commodities have history)
$recOf = @{}
try { foreach ($h in ((Read-JsonFile "$root\price-history.json").commodities)) { if ($h.record_low) { $recOf[[string]$h.id] = [double]$h.record_low.price } } } catch {}

# trend slugs = the keep-list, not a re-derived history rule. 2026-08-04: the old ">=3 weeks" copy here
# emitted links to all 492 trend pages; 472 of those are being unpublished. Deliberately NOT wrapped in a
# silent try/catch any more - a missing keep-list must fail the build, not quietly drop every trend link.
. (Join-Path $root '..\lib\trend-keep.ps1')
$trendIds = @{}
foreach ($k in (Get-TrendKeep)) { $trendIds[[string]$k] = $true }

$items = @(); $seen = @{}
foreach ($c in $comms) {
  $id = [string]$c.id
  if (-not $feedIng.ContainsKey($id)) { continue }
  $f = $feedIng[$id]
  $cat = if ($catOf.ContainsKey($id)) { $catOf[$id] } else { 'Pantry & Beverages' }
  $rec = if ($recOf.ContainsKey($id)) { $recOf[$id] } else { $null }
  $t = if ($trendIds.ContainsKey($id)) { $id + '-price-omaha' } else { $null }
  $se = if ($f.sale_end) { [string]$f.sale_end } else { $null }
  $items += ,@{ k=$id; l=[string]$c.label; u=[string]$f.unit; c=$cat; f=[double]$f.cheapest; fs=[string]$f.store; rec=$rec; t=$t; w=1; se=$se }
  $seen[$id] = $true
}
$ri = Read-JsonFile "$root\out\recipe-board.json"
foreach ($r in $ri.comparison) {
  $id = [string]$r.id
  if ($seen.ContainsKey($id) -or -not $feedIng.ContainsKey($id)) { continue }
  $f = $feedIng[$id]
  $se2 = if ($f.sale_end) { [string]$f.sale_end } else { $null }
  $items += ,@{ k=$id; l=[string]$r.commodity; u=[string]$f.unit; c=[string]$r.category; f=[double]$f.cheapest; fs=[string]$f.store; rec=$null; t=$null; w=0; se=$se2 }
  $seen[$id] = $true
}

function JStr([string]$s){ '"' + ($s -replace '\\','\\\\' -replace '"','\"') + '"' }
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append('var ST={week:' + (JStr ([string]$feed.week_of)) + ',items:[')
$first = $true
foreach ($i in $items) {
  if (-not $first) { [void]$sb.Append(',') }; $first = $false
  $recJ = if ($i.rec -ne $null) { [string]([math]::Round($i.rec,4)) } else { 'null' }
  $tJ = if ($i.t) { JStr $i.t } else { 'null' }
  $seJ = if ($i.se) { JStr $i.se } else { 'null' }
  [void]$sb.Append('{"k":' + (JStr $i.k) + ',"l":' + (JStr $i.l) + ',"u":' + (JStr $i.u) + ',"c":' + (JStr $i.c) + ',"f":' + ([string]$i.f) + ',"fs":' + (JStr $i.fs) + ',"rec":' + $recJ + ',"t":' + $tJ + ',"w":' + $i.w + ',"se":' + $seJ + '}')
}
[void]$sb.Append(']};')
[IO.File]::WriteAllText("$root\staples-data.js", $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
"WROTE staples-data.js  items=$($items.Count)  ($([math]::Round((Get-Item "$root\staples-data.js").Length/1KB,1)) KB)"
"weekly(w=1): " + (@($items | Where-Object { $_.w -eq 1 }).Count) + "   recipe(w=0): " + (@($items | Where-Object { $_.w -eq 0 }).Count)
"with records: " + (@($items | Where-Object { $_.rec -ne $null }).Count) + "   with trend links: " + (@($items | Where-Object { $_.t }).Count)
"categories: " + ((@($items | ForEach-Object { $_.c }) | Select-Object -Unique) -join ' | ')