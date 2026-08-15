# build-sams-data.ps1 - emits the embedded dataset for the "Is Sam's Club Worth It?" calculator.
# For every tracked item where Sam's Club has a price, computes the spread between Sam's per-unit
# price and the best NON-membership store's per-unit price. Negative spreads (Sam's loses) are
# kept on purpose; the tool is only honest if it shows both sides.
# Data: newest out\comparison-<week>.json (prefer verified-<week>.json when at least as fresh,
# same rule as build-deals-page.ps1) + out\recipe-board.json (weekly board wins on id collisions).
# Output: sams-data.js  ->  splice into sams-tool-template.html at //__DATA__
#         -> C:\Codex\ThriftyCrew\sams-worth-it-tool.html
$ErrorActionPreference = 'Stop'
$root = 'C:\Codex\ThriftyCrew\grocery'
$outDir = Join-Path $root 'out'

# ---- pick the weekly board (mirror build-deals-page.ps1 selection) ----
$cmpF = (Get-ChildItem (Join-Path $outDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1)
$CompareFile = $cmpF.FullName
try {
  $wk = (Get-Content $cmpF.FullName -Raw | ConvertFrom-Json).week_of
  $verF = Join-Path $outDir ("verified-" + $wk + ".json")
  if ((Test-Path $verF) -and ((Get-Item $verF).LastWriteTime -ge $cmpF.LastWriteTime)) { $CompareFile = $verF }
} catch {}
Write-Host "board: $CompareFile"
$doc = Get-Content $CompareFile -Raw | ConvertFrom-Json
$week = [string]$doc.week_of

# category labels for the 29 weekly commodities (recipe-board rows carry their own category)
$catOf = @{}
foreach ($c in ((Get-Content (Join-Path $root 'categories.json') -Raw | ConvertFrom-Json).categories)) {
  foreach ($cid in $c.commodities) { $catOf[[string]$cid] = [string]$c.label }
}

function Get-SpreadRow($row, [string]$cat) {
  $sams = $null; $bestOther = $null; $otherStore = ''
  foreach ($s in $row.stores) {
    $pu = [double]$s.per_unit
    if ($pu -le 0) { continue }
    if ([string]$s.store -eq "Sam's Club") {
      if ($sams -eq $null -or $pu -lt $sams) { $sams = $pu }
    } else {
      if ($bestOther -eq $null -or $pu -lt $bestOther) { $bestOther = $pu; $otherStore = [string]$s.store }
    }
  }
  if ($sams -eq $null -or $bestOther -eq $null) { return $null }
  $sp = ($bestOther - $sams) / $bestOther
  $label = if ($row.commodity) { [string]$row.commodity } else { [string]$row.id }
  return @{ k=[string]$row.id; l=$label; u=[string]$row.unit; s=[math]::Round($sams,4); o=[math]::Round($bestOther,4); os=$otherStore; sp=[math]::Round($sp,4); c=$cat }
}

$items = @(); $seen = @{}
foreach ($r in $doc.comparison) {
  $id = [string]$r.id
  $cat = if ($catOf.ContainsKey($id)) { $catOf[$id] } else { 'Pantry & Beverages' }
  $it = Get-SpreadRow $r $cat
  if ($it -ne $null) { $items += ,$it; $seen[$id] = $true }
}
$rb = Get-Content (Join-Path $outDir 'recipe-board.json') -Raw | ConvertFrom-Json
foreach ($r in $rb.comparison) {
  $id = [string]$r.id
  if ($seen.ContainsKey($id)) { continue }
  $cat = if ($r.category) { [string]$r.category } else { 'Pantry & Beverages' }
  $it = Get-SpreadRow $r $cat
  if ($it -ne $null) { $items += ,$it; $seen[$id] = $true }
}

# stable order: biggest Sam's win first (nice default reading order in the picker sections)
$items = @($items | Sort-Object { -1.0 * [double]$_.sp })

# ---- emit sams-data.js ----
function JStr([string]$s){ '"' + ($s -replace '\\','\\\\' -replace '"','\"') + '"' }
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append('var SC={week:' + (JStr $week) + ',fee:50,feePlus:110,items:[')
$first = $true
foreach ($i in $items) {
  if (-not $first) { [void]$sb.Append(',') }; $first = $false
  [void]$sb.Append('{"k":' + (JStr $i.k) + ',"l":' + (JStr $i.l) + ',"u":' + (JStr $i.u) + ',"c":' + (JStr $i.c) + ',"s":' + ([string]$i.s) + ',"o":' + ([string]$i.o) + ',"os":' + (JStr $i.os) + ',"sp":' + ([string]$i.sp) + '}')
}
[void]$sb.Append(']};')
$dataPath = Join-Path $root 'sams-data.js'
[IO.File]::WriteAllText($dataPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

# ---- splice into the template ----
$tplPath = Join-Path $root 'sams-tool-template.html'
if (Test-Path $tplPath) {
  $tpl = Get-Content $tplPath -Raw
  $html = $tpl.Replace('//__DATA__', $sb.ToString())
  $toolPath = 'C:\Codex\ThriftyCrew\sams-worth-it-tool.html'
  [IO.File]::WriteAllText($toolPath, $html, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host ("WROTE " + $toolPath + "  (" + [math]::Round((Get-Item $toolPath).Length/1KB,1) + " KB)")
} else {
  Write-Host "template not found ($tplPath); wrote data only"
}

# ---- report ----
$wins  = @($items | Where-Object { [double]$_.sp -gt 0 })
$loses = @($items | Where-Object { [double]$_.sp -lt 0 })
$ties  = @($items | Where-Object { [double]$_.sp -eq 0 })
Write-Host ("WROTE sams-data.js  week=$week  items=$($items.Count)  (" + [math]::Round((Get-Item $dataPath).Length/1KB,1) + " KB)")
Write-Host ("Sam's wins: $($wins.Count)   loses: $($loses.Count)   ties: $($ties.Count)")
$avgSp = 0.0; foreach ($i in $items) { $avgSp += [double]$i.sp }
if ($items.Count -gt 0) { $avgSp = $avgSp / $items.Count }
Write-Host ("equal-weight avg spread across all items: " + [math]::Round($avgSp * 100, 1) + "%")
Write-Host ""
Write-Host "Top 10 Sam's WINS (Sam's vs best other store, per unit):"
$fmt = '  {0,-38} Sam''s ${1}/{2} vs ${3} at {4}   spread {5}%'
foreach ($i in @($items | Sort-Object { -1.0 * [double]$_.sp } | Select-Object -First 10)) {
  Write-Host ($fmt -f $i.l, $i.s, $i.u, $i.o, $i.os, [math]::Round([double]$i.sp*100,1))
}
Write-Host ""
Write-Host "Top 10 Sam's LOSSES:"
foreach ($i in @($items | Sort-Object { [double]$_.sp } | Select-Object -First 10)) {
  Write-Host ($fmt -f $i.l, $i.s, $i.u, $i.o, $i.os, [math]::Round([double]$i.sp*100,1))
}
