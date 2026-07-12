<#
  build-trend-pages.ps1 - Renders one self-contained HTML fragment per tracked grocery staple
  to out\trend\<id>.html for the Thrifty Crew price trend pages (SEO play).

  Data:
    price-history.json          -> weekly cheapest history + record lows per commodity
    out\comparison-*.json (newest) -> current-week per-store spread (used for item names when
                                      its week_of matches the history's newest week; the
                                      history's newest per_store is always the price source so
                                      the spread never disagrees with the headline number)

  Rules:
    - Only commodities with at least $MinWeeks history entries are rendered.
    - Fragments only (no <h1>, Ghost's post title is the H1). All CSS inline, tp- prefixed.
    - PowerShell 5.1 safe. UTF-8 no BOM output.
#>
param(
  [string]$HistoryFile = '',
  [string]$OutDir = '',
  [int]$MinWeeks = 3,
  [int]$MaxBars = 10
)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$tcChartJs = [IO.File]::ReadAllText((Join-Path $here 'tc-chart.js'), [Text.Encoding]::UTF8)
if ([string]::IsNullOrWhiteSpace($HistoryFile)) { $HistoryFile = Join-Path $here 'price-history.json' }
if ([string]::IsNullOrWhiteSpace($OutDir))      { $OutDir      = Join-Path $here 'out\trend' }

$inv  = [System.Globalization.CultureInfo]::InvariantCulture
$utf8 = New-Object System.Text.UTF8Encoding($false)

# ---------- helpers ----------

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

function Format-Week { param([string]$w)
  $d = [datetime]::ParseExact($w, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
  return $d.ToString('MMM d', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-WeekShort { param([string]$w)
  $d = [datetime]::ParseExact($w, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
  return $d.ToString('M/d', [System.Globalization.CultureInfo]::InvariantCulture)
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

function Get-UnitPhrase { param([string]$u)
  switch ($u) {
    'lb'     { return 'per lb' }
    'oz'     { return 'per oz' }
    'floz'   { return 'per fl oz' }
    'each'   { return 'each' }
    'dozen'  { return 'per dozen' }
    'gallon' { return 'per gallon' }
    default  { return ('per ' + $u) }
  }
}

function New-TrendSvg { param($entries, [bool]$currentIsRecord)
  $n = $entries.Count
  $W = 340; $padL = 10; $padR = 10; $top = 24; $plotH = 116
  $baseY = $top + $plotH
  $plotW = $W - $padL - $padR
  $slot = $plotW / $n
  $barW = [math]::Round(($slot * 0.62), 1)
  if ($barW -gt 52) { $barW = 52 }
  $max = 0.0
  foreach ($e in $entries) { if ([double]$e.cheapest_price -gt $max) { $max = [double]$e.cheapest_price } }
  if ($max -le 0) { $max = 1 }
  $fs = 11
  if ($n -gt 6) { $fs = 9 }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('<svg class="tp-svg" viewBox="0 0 340 190" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Weekly cheapest price, one bar per tracked week">')
  [void]$sb.Append('<line x1="' + $padL + '" y1="' + $baseY + '" x2="' + ($W - $padR) + '" y2="' + $baseY + '" stroke="#d6d3cb" stroke-width="1"/>')
  for ($i = 0; $i -lt $n; $i++) {
    $e = $entries[$i]
    $p = [double]$e.cheapest_price
    $h = [math]::Round((($p / $max) * $plotH), 1)
    if ($h -lt 3) { $h = 3 }
    $x = [math]::Round(($padL + ($slot * $i) + (($slot - $barW) / 2)), 1)
    $y = [math]::Round(($baseY - $h), 1)
    $cx = [math]::Round(($x + ($barW / 2)), 1)
    $fill = '#e2a43c'
    if (($i -eq ($n - 1)) -and $currentIsRecord) { $fill = '#1f7a4d' }
    [void]$sb.Append('<rect x="' + $x + '" y="' + $y + '" width="' + $barW + '" height="' + $h + '" rx="2" fill="' + $fill + '"/>')
    [void]$sb.Append('<text x="' + $cx + '" y="' + [math]::Round(($y - 5), 1) + '" text-anchor="middle" font-size="' + $fs + '" font-weight="600" fill="#374151">' + (Format-Price $p) + '</text>')
    [void]$sb.Append('<text x="' + $cx + '" y="' + ($baseY + 15) + '" text-anchor="middle" font-size="9.5" fill="#6b7280">' + (Format-WeekShort $e.week_of) + '</text>')
  }
  [void]$sb.Append('</svg>')
  return $sb.ToString()
}

$tpCss = @'
<style>
.tp-wrap{line-height:1.55;margin:0}
.tp-hero{background:#f7f3ea;border:1px solid #e8dfc9;border-radius:12px;padding:18px 20px;margin:0 0 18px}
.tp-kicker{font-size:.78rem;text-transform:uppercase;letter-spacing:.08em;color:#8a7a54;font-weight:700;margin:0 0 4px}
.tp-price{font-size:2.3rem;font-weight:800;color:#1f2937;line-height:1.1}
.tp-price .tp-unit{font-size:1.1rem;font-weight:600;color:#6b7280}
.tp-where{font-size:1.02rem;color:#374151;margin-top:3px}
.tp-record{margin:0 0 14px;color:#374151}
.tp-read{background:#eef5f0;border-left:4px solid #1f7a4d;padding:10px 14px;border-radius:0 8px 8px 0;margin:0 0 20px;color:#1f3b2c}
.tp-chartwrap{margin:6px 0 4px;max-width:560px}
.tp-svg{width:100%;max-width:560px;height:auto;display:block}
.tcc-none{font-size:.9rem;color:#8a94a6;text-align:center;padding:2.2em 0}
.tcc-leg{display:flex;flex-wrap:wrap;gap:8px;margin-top:10px}
.tcc-chip{display:inline-flex;align-items:center;gap:7px;border:1px solid #e2e8f0;background:#fff;border-radius:999px;padding:5px 12px;font-size:.82rem;color:#3a4658;font-weight:700;cursor:pointer;font-family:inherit;white-space:nowrap}
.tcc-chip i{width:16px;height:3px;border-radius:2px;display:inline-block}
.tcc-chip.is-off{opacity:.4}
.tcc-chip.is-off i{background:#c3cad6!important}
.tcc-chip:hover{border-color:#E2A43C}
.tp-note{font-size:.9rem;color:#6b7280;margin:4px 0 20px}
.tp-table{width:100%;border-collapse:collapse;margin:6px 0 22px;font-size:.95rem}
.tp-table th{text-align:left;border-bottom:2px solid #e5e7eb;padding:6px 8px;font-size:.82rem;text-transform:uppercase;letter-spacing:.04em;color:#6b7280}
.tp-table td{border-bottom:1px solid #f0f0ef;padding:6px 8px;vertical-align:top}
.tp-low td{background:#f2f8f4;font-weight:600}
.tp-item{font-size:.85rem;color:#6b7280;font-weight:400}
.tp-links{margin:0 0 10px}
.tp-foot{font-size:.85rem;color:#9ca3af;margin:0}
</style>
'@

# ---------- load data ----------

if (-not (Test-Path $HistoryFile)) { throw "History file not found: $HistoryFile" }
$data = Get-Content $HistoryFile -Raw | ConvertFrom-Json

$cmp = $null
$cmpById = @{}
$cmpFiles = @(Get-ChildItem (Join-Path $here 'out') -Filter 'comparison-*.json' -ErrorAction SilentlyContinue | Sort-Object Name)
if ($cmpFiles.Count -gt 0) {
  $cmp = Get-Content $cmpFiles[-1].FullName -Raw | ConvertFrom-Json
  foreach ($row in $cmp.comparison) { $cmpById[$row.id] = $row }
  Write-Host ("Comparison file: {0} (week_of {1})" -f $cmpFiles[-1].Name, $cmp.week_of)
} else {
  Write-Host 'No comparison-*.json found; spread tables will use history per_store only.'
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# ---------- render ----------

$generated = @()
$skipped = @()

foreach ($c in $data.commodities) {
  # recipe-board items (src='recipe', tracked since 2026-07-11 for the history popup) do NOT get
  # trend pages yet - expanding to ~155 more public pages is a deliberate decision for later.
  if ($c.src -eq 'recipe') { continue }
  $hist = @($c.history | Sort-Object week_of)
  if ($hist.Count -lt $MinWeeks) {
    $skipped += ('{0} ({1} weeks)' -f $c.id, $hist.Count)
    continue
  }

  $cur = $hist[$hist.Count - 1]
  $rec = $c.record_low
  $curP = [math]::Round([double]$cur.cheapest_price, 4)
  $recP = [math]::Round([double]$rec.price, 4)
  $unitSuf = Get-UnitSuffix $c.unit
  $unitPhr = Get-UnitPhrase $c.unit
  $isRecordNow = ($curP -le ($recP + 0.0005))
  $newRecordThisWeek = ($isRecordNow -and ($rec.week_of -eq $cur.week_of))

  # chart entries: newest MaxBars
  $chartEntries = $hist
  if ($hist.Count -gt $MaxBars) { $chartEntries = @($hist | Select-Object -Last $MaxBars) }

  # record status sentence
  if ($newRecordThisWeek) {
    $recStatus = 'This week sets that low.'
  } elseif ($isRecordNow) {
    $recStatus = 'This week ties that low.'
  } else {
    $pctAbove = [math]::Round((($curP - $recP) / $recP) * 100)
    $recStatus = 'This week is about ' + $pctAbove + ' percent above that low.'
  }

  # honest read
  $ratio = 999.0
  if ($recP -gt 0) { $ratio = $curP / $recP }
  if ($isRecordNow) {
    $read = 'At ' + (Format-Price $curP) + ' ' + $unitPhr + ', this is the best price we have tracked for ' + (Esc $c.label).ToLower() + '. If it is on your list, this is a good week to stock up.'
  } elseif ($ratio -le 1.05) {
    $read = (Format-Price $curP) + ' is close to the tracked low of ' + (Format-Price $recP) + ', so this is a fine week to buy.'
  } elseif ($ratio -gt 1.15) {
    $read = 'This one is usually cheaper. The tracked low is ' + (Format-Price $recP) + ' ' + $unitPhr + ' at ' + (Esc $rec.store) + ', so unless you need it right now, it may pay to wait a week or two.'
  } else {
    $read = (Format-Price $curP) + ' sits in the normal range of what we have seen so far. Buy it if you need it, but there is no rush.'
  }

  # current-week store spread (history per_store is the price source; comparison adds item names when weeks match)
  $spread = @()
  $cmpRow = $null
  if ($cmpById.ContainsKey($c.id)) { $cmpRow = $cmpById[$c.id] }
  $useCmpItems = ($null -ne $cmpRow -and $null -ne $cmp -and ($cmp.week_of -eq $cur.week_of))
  $itemByStore = @{}
  if ($useCmpItems) {
    foreach ($s in $cmpRow.stores) { $itemByStore[[string]$s.store] = [string]$s.item }
  }
  foreach ($prop in $cur.per_store.PSObject.Properties) {
    $itm = ''
    if ($itemByStore.ContainsKey($prop.Name)) { $itm = $itemByStore[$prop.Name] }
    $spread += New-Object PSObject -Property @{ store = [string]$prop.Name; price = [double]$prop.Value; item = $itm }
  }
  $spread = @($spread | Sort-Object price, store)
  $anyItems = $false
  foreach ($s in $spread) { if ($s.item -ne '') { $anyItems = $true } }

  # ---------- assemble fragment ----------
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('<div class="tp-wrap">')
  [void]$sb.AppendLine($tpCss)

  # hero
  [void]$sb.AppendLine('<div class="tp-hero">')
  [void]$sb.AppendLine('  <p class="tp-kicker">This week in Omaha</p>')
  [void]$sb.AppendLine('  <div class="tp-price">' + (Format-Price $curP) + '<span class="tp-unit">' + (Esc $unitSuf) + '</span></div>')
  [void]$sb.AppendLine('  <div class="tp-where">Cheapest at ' + (Esc $cur.cheapest_store) + ', week of ' + (Format-Week $cur.week_of) + '</div>')
  [void]$sb.AppendLine('</div>')

  # record line
  [void]$sb.AppendLine('<p class="tp-record"><strong>Record low we have tracked:</strong> ' + (Format-Price $recP) + ' ' + (Esc $unitPhr) + ' at ' + (Esc $rec.store) + ' (week of ' + (Format-Week $rec.week_of) + '). ' + $recStatus + '</p>')

  # honest read
  [void]$sb.AppendLine('<p class="tp-read">' + $read + '</p>')

  # chart: interactive per-store LINE chart (2026-07-11, Brad's spec: line graph + tappable store
  # legend to hide/show lines, all on by default). Data embedded per page; tc-chart.js inlined once.
  [void]$sb.AppendLine('<h2>Price history</h2>')
  $cEntries = $hist
  if ($hist.Count -gt 40) { $cEntries = @($hist | Select-Object -Last 40) }
  $cw = @($cEntries | ForEach-Object { ([string]$_.week_of).Substring(5) })
  $cStores = [ordered]@{}
  foreach ($e in $cEntries) { if ($e.per_store) { foreach ($p in $e.per_store.PSObject.Properties) { $cStores[[string]$p.Name] = $true } } }
  if ($cStores.Count -gt 0) {
    $sParts = @()
    foreach ($sn in $cStores.Keys) {
      $vals = @()
      foreach ($e in $cEntries) {
        $v = $null
        if ($e.per_store) { $pp = $e.per_store.PSObject.Properties | Where-Object { $_.Name -eq $sn } | Select-Object -First 1; if ($pp) { $v = [double]$pp.Value } }
        if ($null -ne $v -and $v -gt 0) { $vals += ,([string]([math]::Round($v, 4))) } else { $vals += ,'null' }
      }
      $sParts += ('"' + ($sn -replace '\\','\\\\' -replace '"','\"') + '":[' + ($vals -join ',') + ']')
    }
    $cJson = '{"u":"' + $unit + '","w":[' + ((@($cw | ForEach-Object { '"' + $_ + '"' })) -join ',') + '],"s":{' + ($sParts -join ',') + '}}'
    [void]$sb.AppendLine('<div class="tp-chartwrap" id="tp-chart"></div>')
    [void]$sb.AppendLine('<script>')
    [void]$sb.AppendLine($tcChartJs)
    [void]$sb.AppendLine('(function(){ var el = document.getElementById("tp-chart"); if (el && typeof tcChart === "function") tcChart(el, ' + $cJson + '); })();')
    [void]$sb.AppendLine('</script>')
    [void]$sb.AppendLine('<p class="tp-note">Each line is one store. Tap a store below the chart to hide or show it; tap a dot for the exact price. Daily points for the last three weeks, weekly before that.</p>')
  } else {
    [void]$sb.AppendLine('<div class="tp-chartwrap">')
    [void]$sb.AppendLine((New-TrendSvg -entries $chartEntries -currentIsRecord $isRecordNow))
    [void]$sb.AppendLine('</div>')
    [void]$sb.AppendLine('<p class="tp-note">' + $hist.Count + ' weeks of tracking so far, growing every week.</p>')
  }

  # weekly table, newest first
  [void]$sb.AppendLine('<h2>Week by week</h2>')
  [void]$sb.AppendLine('<table class="tp-table">')
  [void]$sb.AppendLine('<thead><tr><th>Week of</th><th>Cheapest price</th><th>Store</th></tr></thead>')
  [void]$sb.AppendLine('<tbody>')
  for ($i = $hist.Count - 1; $i -ge 0; $i--) {
    $e = $hist[$i]
    $rowCls = ''
    if ([math]::Round([double]$e.cheapest_price, 4) -le ($recP + 0.0005)) { $rowCls = ' class="tp-low"' }
    [void]$sb.AppendLine('<tr' + $rowCls + '><td>' + (Format-Week $e.week_of) + '</td><td>' + (Format-Price ([double]$e.cheapest_price)) + ' ' + (Esc $unitPhr) + '</td><td>' + (Esc $e.cheapest_store) + '</td></tr>')
  }
  [void]$sb.AppendLine('</tbody></table>')

  # store spread
  [void]$sb.AppendLine('<h2>Who has it cheapest this week</h2>')
  [void]$sb.AppendLine('<table class="tp-table">')
  if ($anyItems) {
    [void]$sb.AppendLine('<thead><tr><th>Store</th><th>Price</th><th>Item</th></tr></thead>')
  } else {
    [void]$sb.AppendLine('<thead><tr><th>Store</th><th>Price</th></tr></thead>')
  }
  [void]$sb.AppendLine('<tbody>')
  $first = $true
  foreach ($s in $spread) {
    $rowCls = ''
    if ($first) { $rowCls = ' class="tp-low"'; $first = $false }
    $cells = '<td>' + (Esc $s.store) + '</td><td>' + (Format-Price $s.price) + ' ' + (Esc $unitPhr) + '</td>'
    if ($anyItems) { $cells = $cells + '<td><span class="tp-item">' + (Esc $s.item) + '</span></td>' }
    [void]$sb.AppendLine('<tr' + $rowCls + '>' + $cells + '</tr>')
  }
  [void]$sb.AppendLine('</tbody></table>')

  # footer links + tracking line
  [void]$sb.AppendLine('<p class="tp-links"><a href="/omaha-grocery-prices/?ref=trend">See the full live Omaha price board</a> &middot; <a href="/omaha-price-tracker/?ref=trend">All tracked staples</a></p>')
  [void]$sb.AppendLine('<p class="tp-foot">Tracked weekly across Hy-Vee, Baker&#39;s, Family Fare, Aldi, Sam&#39;s Club and Walmart in Omaha since June 2026. This page updates every week.</p>')
  [void]$sb.Append('</div>')

  $outPath = Join-Path $OutDir ($c.id + '.html')
  [IO.File]::WriteAllText($outPath, $sb.ToString(), $utf8)
  $generated += $c.id
  Write-Host ('  wrote ' + $c.id + '.html  (' + $hist.Count + ' weeks, current ' + (Format-Price $curP) + ' at ' + $cur.cheapest_store + ')')
}

Write-Host ''
Write-Host ('Generated {0} trend pages in {1}' -f $generated.Count, $OutDir) -ForegroundColor Green
if ($skipped.Count -gt 0) {
  Write-Host ('Skipped (fewer than {0} weeks of history): {1}' -f $MinWeeks, ($skipped -join ', ')) -ForegroundColor Yellow
}
