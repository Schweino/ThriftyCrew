<#
  build-deals-page.ps1 - Renders the weekly Omaha cross-store price board into a self-contained,
  filterable HTML page (embeddable in a Ghost page). Data-driven: re-run it whenever the board
  refreshes. Groups commodities by food category (categories.json), one ROW per commodity, and
  lays each row's stores out cheapest (left) -> most expensive (right).

  Usage: powershell -ExecutionPolicy Bypass -File build-deals-page.ps1 [-CompareFile <path>] [-Out <path>]
#>
param([string]$CompareFile = "", [string]$OutDir = "", [string]$Out = "", [switch]$Embed)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $CompareFile) {
  $cmpF = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1)
  $CompareFile = $cmpF.FullName
  # Prefer the semantically-verified board (wrong-product winners dropped/de-crowned by the verify pass) when
  # it is at least as fresh as the raw comparison (i.e. re-applied after the latest re-compare); otherwise the
  # raw comparison (fresher prices) wins so a stale verified snapshot never overrides today's daily re-pricing.
  try { $wk = (Get-Content $cmpF.FullName -Raw | ConvertFrom-Json).week_of; $verF = Join-Path $OutDir ("verified-" + $wk + ".json"); if ((Test-Path $verF) -and ((Get-Item $verF).LastWriteTime -ge $cmpF.LastWriteTime)) { $CompareFile = $verF } } catch {}
}
if (-not $Out) { $Out = Join-Path $OutDir 'deals-page.html' }

$doc  = Get-Content $CompareFile -Raw | ConvertFrom-Json
$cats = (Get-Content (Join-Path $root 'categories.json') -Raw | ConvertFrom-Json).categories | Sort-Object order
$week = [string]$doc.week_of

# comparison rows keyed by commodity id
$byId = @{}; foreach ($r in $doc.comparison) { $byId[[string]$r.id] = $r }

# optional: recipe-ingredient board (the 100 meal-prep recipes' ingredients, all 6 stores). Additive; renders below the weekly staples when present.
$riDoc = $null; $riCats = @()
$riFile = Join-Path $OutDir 'recipe-board.json'
if (Test-Path $riFile) { $riDoc = Get-Content $riFile -Raw | ConvertFrom-Json; $riCats = @($riDoc.comparison | ForEach-Object { [string]$_.category } | Select-Object -Unique) }

# durable per-store product URLs (survives weekly regeneration). Keyed by commodity id -> store name -> {url,price,size,name}.
$purls = @{}
$purlFile = Join-Path $root 'product-urls.json'
if (Test-Path $purlFile) {
  $pd = Get-Content $purlFile -Raw | ConvertFrom-Json
  foreach ($p in $pd.items.PSObject.Properties) {
    $sm = @{}; foreach ($sp in $p.Value.PSObject.Properties) { if ($sp.Value -and $sp.Value.url) { $sm[[string]$sp.Name] = $sp.Value } }
    $purls[[string]$p.Name] = $sm
  }
}
# per-unit of a stored link, in the board's $unit, from {price,size} - used to SUPPRESS a clearly-wrong link.
function LinkPU([string]$size, [string]$unit, [double]$price) {
  $s = ([string]$size).ToLower().Trim()
  $up = [regex]::Match($s, '\$?\s*([0-9]+(?:\.[0-9]+)?)\s*/\s*(fl\s*oz|floz|oz|lb|ea|each|ct|count)')
  if ($up.Success) { $v=[double]$up.Groups[1].Value; $un=($up.Groups[2].Value -replace '\s','') -replace 'fl',''; switch ($unit) { 'lb'{if($un -eq 'lb'){return $v}; if($un -eq 'oz'){return $v*16}} 'oz'{if($un -eq 'oz'){return $v}; if($un -eq 'lb'){return $v/16}} 'floz'{if($un -match 'oz'){return $v}; if($un -eq 'lb'){return $v/16}} 'each'{if($un -match '^(ea|each|ct|count)$'){return $v}; return $price} 'dozen'{if($un -match '^(ea|each|ct|count)$'){return $v*12}; return $price} } }
  if ($price -le 0) { return $null }
  $q = [regex]::Match($s, '([0-9]+(?:\.[0-9]+)?)\s*(fl\s*oz|floz|oz|lbs?|ct|count|ea|pk|gal|dozen|doz)')
  $n = if ($q.Success) { [double]$q.Groups[1].Value } else { $null }
  $un = if ($q.Success) { ($q.Groups[2].Value -replace '\s','') -replace 'fl','' } else { '' }
  # bare-unit size ("lb","per lb","gallon","dozen","each") = one of that unit -> per-unit is the price itself
  if (-not $q.Success) { $bu=[regex]::Match($s,'\b(lbs?|gal|gallon|dozen|doz|each|ea)\b'); if ($bu.Success) { $n=1; $un=$bu.Groups[1].Value -replace '^gallon$','gal' -replace '^doz$','dozen' } }   # anchored: unanchored 'doz'->'dozen' corrupts 'dozen'
  $pk = [regex]::Match($s, '([0-9]+)\s*(pk|pack)\b'); if ($pk.Success -and $n -and ($un -match '^(oz|lbs?|gal)$')) { $n = $n * [double]$pk.Groups[1].Value }
  switch ($unit) {
    'lb'    { if ($un -match '^lbs?$' -and $n) { return $price/$n }; if ($un -eq 'oz' -and $n) { return $price/($n/16) }; return $null }
    'oz'    { if ($un -eq 'oz' -and $n) { return $price/$n }; if ($un -match '^lbs?$' -and $n) { return $price/(16*$n) }; if ($un -eq 'gal' -and $n) { return $price/(128*$n) }; return $null }
    'floz'  { if ($un -match 'oz' -and $n) { return $price/$n }; if ($un -eq 'gal' -and $n) { return $price/(128*$n) }; return $null }
    'each'  { if ($un -match '^(ct|count|ea|pk)$' -and $n) { return $price/$n }; if ($un -match '^(dozen|doz)$') { return $price/12 }; if ($n -eq 1) { return $price }; return $null }
    'dozen' { if ($un -match '^(dozen|doz)$') { return $price }; if ($un -match '^(ct|count|ea)$' -and $n) { return $price/($n/12) }; if ($n -eq 1) { return $price }; return $null }
    'gallon'{ if ($un -eq 'gal' -and $n) { return $price/$n }; if ($n -eq 1) { return $price }; return $null }
    default { return $null }
  }
  return $null
}
# Respect the audits: suppress a link the name/form-drift audit flags as a clearly WRONG product (a
# fresh commodity linked to a frozen/canned item), which the price gate alone can miss when the per-unit
# happens to be close. Run audit-name-drift.ps1 before build so this file is current.
$formFlip = @{}
$ndFile = Join-Path $OutDir 'name-drift.json'
if (Test-Path $ndFile) { try { $nd = Get-Content $ndFile -Raw | ConvertFrom-Json; foreach ($f in $nd.flags) { if ($f.reason -eq 'form-flip') { $formFlip[([string]$f.id + '|' + [string]$f.store)] = $true } } } catch {} }
# Tidy a raw board item name for on-chip display: drop trailing ad-price/size fluff, cap length.
function CleanItemName([string]$item) {
  if (-not $item) { return '' }
  $t = [string]$item
  $t = $t -replace ',?\s*(?:[0-9]+\s*/\s*)?\$[0-9]+(?:\.[0-9]{2})?\s*(?:\.[0-9]{2}\s*each)?\s*(?:/?\s*(?:lb|ea|each|oz|fl\s*oz|ct|count|pk|gal|dozen)\.?)?\s*$',''  # trailing "$1.99 lb." / "10/ $6 .60 each" / "2/$5"
  $t = $t -replace '\s*\((?:reg[^)]*|[0-9][^)]*)\)\s*$',''  # trailing "(reg 5.98)" / "(30 Ct)"
  $t = ($t -replace '\s+',' ').Trim(' ,-/')
  if ($t.Length -gt 54) { return (HtmlEnc ($t.Substring(0,52).Trim())) + '&hellip;' }
  return (HtmlEnc $t)
}
# Chip footer: a "See item" LINK when we have a price-consistent product URL; otherwise the ITEM NAME as
# plain text (so a shopper still knows exactly WHAT the price is for - by-weight produce/meat and flyer-only
# sales that have no clickable product page). Empty only when we have neither a link nor a name.
function SeeLink([string]$id, [string]$store, [string]$boardItem, [double]$boardPU, [string]$unit) {
  $url = $null
  if (($purls.ContainsKey($id)) -and ($purls[$id].ContainsKey($store)) -and (-not $formFlip.ContainsKey($id + '|' + $store))) {
    $lnk = $purls[$id][$store]
    if ($lnk.url) {
      $ok = $true
      # suppress a link whose product per-unit is clearly off the board price shown (>30%) - missing beats wrong
      if ($boardPU -gt 0) { $lpu = LinkPU ([string]$lnk.size) $unit ([double]$lnk.price); if (($null -ne $lpu) -and ([math]::Abs($lpu - $boardPU) / $boardPU -gt 0.30)) { $ok = $false } }
      if ($ok) { $url = [string]$lnk.url }
    }
  }
  if ($url) { return "<a class='pg-see' href='" + (HtmlEnc $url) + "' target='_blank' rel='nofollow noopener'>See item &rarr;</a>" }
  $nm = CleanItemName $boardItem
  if ($nm) { return "<span class='pg-itemname' title='" + $nm + "'>" + $nm + "</span>" }
  return ''
}

# store scoreboard: how many commodities each store is the outright cheapest on (the summary a shopper wants first)
$storeOrder = @('Hy-Vee','Aldi','Family Fare',"Baker's","Sam's Club",'Walmart')
$wins = [ordered]@{}; foreach ($s in $storeOrder) { $wins[$s] = 0 }
foreach ($r in $doc.comparison) { $cs = [string]$r.cheapest_store; if ($wins.Contains($cs)) { $wins[$cs]++ } }
if ($riDoc) { foreach ($r in $riDoc.comparison) { $cs = [string]$r.cheapest_store; if ($wins.Contains($cs)) { $wins[$cs]++ } } }

# short store display names + stable column color accents
$shortName = @{ 'Hy-Vee'='Hy-Vee'; 'Aldi'='Aldi'; 'Family Fare'='Family Fare'; "Baker's"="Baker's"; "Sam's Club"="Sam's Club"; 'Walmart'='Walmart' }

# NOTE: must escape single quotes too - several attributes (title='...', href='...') are single-quoted,
# and store-brand names routinely contain apostrophes (Member's Mark, Driscoll's, Land O'Lakes, Baker's).
function HtmlEnc([string]$s) { if ($null -eq $s) { return '' }; return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;' -replace "'",'&#39;') }

# format a per-unit price for display: cents for oz/fl oz, dollars otherwise
function Fmt-Price([double]$v, [string]$unit) {
  switch ($unit) {
    'oz'    { return ('' + [math]::Round($v*100) + '&cent;/oz') }
    'floz'  { return ('' + [math]::Round($v*100) + '&cent;/fl oz') }
    'lb'    { return ('$' + ('{0:N2}' -f $v) + '/lb') }
    'gallon'{ return ('$' + ('{0:N2}' -f $v) + '/gal') }
    'dozen' { return ('$' + ('{0:N2}' -f $v) + '/dozen') }
    'each'  { return ('$' + ('{0:N2}' -f $v) + ' each') }
    default { return ('$' + ('{0:N2}' -f $v)) }
  }
}
function UnitLabel([string]$unit) {
  switch ($unit) { 'oz'{'per ounce'} 'floz'{'per fl ounce'} 'lb'{'per pound'} 'gallon'{'per gallon'} 'dozen'{'per dozen'} 'each'{'each'} default{$unit} }
}
function Fmt-Date($d) { if ($null -eq $d -or "$d" -eq '') { return '' }; try { return ([datetime]$d).ToString('MMM d') } catch { return [string]$d } }
$pgToday = (Get-Date).Date
# Best-effort: pull a window TIGHTER than the weekly ad out of the sale text (flash / weekend / single day).
# Returns @{from;to} within [$from,$to], or $null. Grocery sale text rarely carries this today, so most
# sale chips fall back to the full weekly window.
function ParseFlashWindow([string]$text, $from, $to) {
  if ($null -eq $from -or $null -eq $to) { return $null }
  $t = ([string]$text).ToLower()
  # explicit M/D date - but NOT when the "date" is really a size/count ("9-12 oz", "10/10 mix & match"):
  # reject a match immediately followed by a unit/count word.
  $m = [regex]::Match($t, '\b(1[0-2]|0?[1-9])[/-]([0-3]?[0-9])\b(?!\s*(?:fl\s*oz|oz|lb|lbs|ct|count|pk|pack|gal|each|ea|cans?|bottles?|rolls?)\b)')
  if ($m.Success) { try { $d = [datetime]::new($from.Year, [int]$m.Groups[1].Value, [int]$m.Groups[2].Value); if ($d -ge $from -and $d -le $to) { return @{ from=$d; to=$d } } } catch {} }
  # weekend = Friday through SUNDAY (capped at the window end), not through the window's last day
  if ($t -match 'weekend') {
    $f=$from; while ($f -le $to -and [int]$f.DayOfWeek -ne 5) { $f=$f.AddDays(1) }
    if ($f -le $to) { $e=$f; while ($e -lt $to -and [int]$e.DayOfWeek -ne 0) { $e=$e.AddDays(1) }; return @{ from=$f; to=$e } }
  }
  foreach ($pair in @(@('sunday',0),@('monday',1),@('tuesday',2),@('wednesday',3),@('thursday',4),@('friday',5),@('saturday',6))) {
    if ($t -match ('\b' + $pair[0] + '\b')) { for ($d=$from; $d -le $to; $d=$d.AddDays(1)) { if ([int]$d.DayOfWeek -eq $pair[1]) { return @{ from=$d; to=$d } } } }
  }
  # "today only" without a date: we can't know WHICH day from the ad text alone - suppress the badge
  # entirely (a missing date beats a wrong one).
  if ($t -match '\btoday only\b|\bone day\b|\b1[- ]day\b') { return @{ suppress=$true } }
  return $null
}
# Effective-dates badge for a SALE chip. "Sale thru <end>" for a weekly sale; actual DATE (never a weekday
# name, per Brad) for a short/flash sale: "Sale <date> only" or "Sale <d1>-<d2>". Empty for everyday prices,
# for stores with no ad window (Sam's/Walmart EDLP), or for a window that has already ended.
function SaleBadge($s, $store) {
  if ([string]$s.type -ne 'sale') { return '' }
  if (-not $adWin.ContainsKey($store)) { return '' }
  $wf = $null; $wt = $null
  try { $wf = [datetime]$adWin[$store].from } catch {}
  try { $wt = [datetime]$adWin[$store].to } catch {}
  if ($null -eq $wt -or $wt.Date -lt $pgToday) { return '' }
  $flash = ParseFlashWindow (([string]$s.ad) + ' ' + ([string]$s.note)) $wf $wt
  if ($flash -and $flash.suppress) { return '' }   # "today only" with no date: no badge beats a wrong date
  if ($flash) {
    if ($flash.from -eq $flash.to) { $label = 'Sale ' + (Fmt-Date $flash.from) + ' only' }
    else { $label = 'Sale ' + (Fmt-Date $flash.from) + '&ndash;' + (Fmt-Date $flash.to) }
  } else { $label = 'Sale thru ' + (Fmt-Date $wt) }
  return "<span class='pg-sale'>" + $label + "</span>"
}

# ---- per-store status: current weekly-ad window (ad-schedule.json) + when the store's prices were last pulled ----
$adWin = @{}
$schedFile = Join-Path $root 'ad-schedule.json'
if (Test-Path $schedFile) { $sc = Get-Content $schedFile -Raw | ConvertFrom-Json; foreach ($s in $sc.stores) { if ($s.current -and $s.current.from) { $adWin[[string]$s.store] = @{ from=[string]$s.current.from; to=[string]$s.current.to } } } }
$storeFiles = @{
  'Hy-Vee'      = @('ads-*.json','regular\hyvee-regular-*.json')
  'Aldi'        = @('ads-*.json','regular\aldi-regular-*.json')
  'Family Fare' = @('ads-*.json','regular\family-fare-regular-*.json')
  "Baker's"     = @('bakers\bakers-deals-*.json','regular\bakers-regular-*.json')
  "Sam's Club"  = @('sams\sams-deals-*.json')
  'Walmart'     = @('regular\walmart-regular-*.json')
}
function NewestUpd($globs) { $m=$null; foreach ($g in $globs) { $f = Get-ChildItem (Join-Path $OutDir $g) -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($f -and (($null -eq $m) -or ($f.LastWriteTime -gt $m))) { $m = $f.LastWriteTime } }; return $m }

# ---- build the category sections ----
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append("<div class='pg-wrap'>")
[void]$sb.Append("<header class='pg-head'>")
if (-not $Embed) { [void]$sb.Append("<h1>Omaha's Cheapest Groceries This Week</h1>") }   # Embed: Ghost post title is the H1
[void]$sb.Append("<p class='pg-sub'>The cheapest place to buy every grocery staple in Omaha this week. Six stores, checked every morning, ranked cheapest first.</p>")
[void]$sb.Append("<p class='pg-note'>Lowest verified price at each store, sale or everyday, checked against the store's own ad or site. Sam's Club prices need a membership.</p>")
[void]$sb.Append("<p class='pg-suggest'>See a cheaper price somewhere? <a href='/suggest-an-item/'>Suggest an item &rarr;</a></p></header>")

# store-status strip is built here but rendered at the BOTTOM of the page (it is transparency fine print;
# it was costing ~200px of prime space above the first price). See the footer section.
$statusSb = New-Object System.Text.StringBuilder
[void]$statusSb.Append("<div class='pg-status'><span class='pg-status-h'>Each store's prices &amp; current ad week</span><div class='pg-status-grid'>")
foreach ($s in $storeOrder) {
  $u = NewestUpd $storeFiles[$s]
  $adTxt = if ($adWin.ContainsKey($s)) { "Ad " + (Fmt-Date $adWin[$s].from) + " &ndash; " + (Fmt-Date $adWin[$s].to) } else { "Everyday prices" }
  $uTxt = if ($u) { "Prices updated " + (Fmt-Date $u) } else { "" }
  [void]$statusSb.Append("<div class='pg-st'><span class='pg-st-store'>" + (HtmlEnc $s) + "</span><span class='pg-st-ad'>" + $adTxt + "</span><span class='pg-st-upd'>" + $uTxt + "</span></div>")
}
[void]$statusSb.Append("</div></div>")
$statusHtml = $statusSb.ToString()

# map weekly category label -> key, so a recipe category with the SAME label reuses that one filter/button (no duplicates)
$weeklyLabelKey = @{}; foreach ($c in $cats) { $weeklyLabelKey[[string]$c.label] = [string]$c.key }
function RiCatKey([string]$label) { if ($weeklyLabelKey.ContainsKey($label)) { return $weeklyLabelKey[$label] } else { return 'ri:' + $label } }

# ---- scoreboard: who wins this week (the shopper's headline stat) ----
$maxWins = 0; foreach ($k in $wins.Keys) { if ($wins[$k] -gt $maxWins) { $maxWins = $wins[$k] } }
[void]$sb.Append("<div class='pg-board'><span class='pg-board-h'>Cheapest-store scoreboard &middot; items each store wins this week</span><div class='pg-board-row'>")
foreach ($s in $storeOrder) {
  $n = $wins[$s]
  $cls = 'pg-score'; if ($n -eq $maxWins -and $n -gt 0) { $cls += ' is-lead' }
  [void]$sb.Append("<div class='" + $cls + "' data-store=`"" + (HtmlEnc $s) + "`"><span class='pg-score-n'>" + $n + "</span><span class='pg-score-s'>" + (HtmlEnc $shortName[$s]) + "</span></div>")
}
[void]$sb.Append("</div></div>")
# ---- trip planner home: ALWAYS visible right under the scoreboard so shoppers know it exists ----
[void]$sb.Append("<div class='pg-tripbox' id='pg-tripbox'><h3>Plan your shopping trip</h3>")
[void]$sb.Append("<p class='pg-tripbox-sub' id='pg-tripbox-sub'>Tick the box next to each item you want to buy, then come back here. Tell us how many stores you are willing to visit and we will split your list for the cheapest trip.</p>")
[void]$sb.Append("<div id='pg-tripbox-body' hidden><p class='pg-tripbox-n'><b id='pg-tripbox-count'>0 items</b> selected. How many stores are you willing to visit?</p><div class='pg-plan-kbtns' id='pg-plan-kbtns'></div><div class='pg-plan-out' id='pg-plan-out'></div><p class='pg-plan-note'>Based on this week's verified per-unit prices. Register totals vary by package size.</p></div></div>")
# hide-Sam's toggle: recomputes the cheapest flags + scoreboard for shoppers without a membership
[void]$sb.Append("<label class='pg-toggle'><input type='checkbox' id='pg-hidesams'><span>Hide Sam's Club</span><span class='pg-toggle-note'>membership required: toggle to see the best price without one</span></label>")

# ---- sticky control bar: search + consolidated filter pills ----
# The two boards' category taxonomies overlap ("Fruit"/"Vegetables" vs "Produce", "Dairy & Eggs" vs
# "Cheese & Dairy") - shoppers should never see that seam. Pills are GROUPS mapping to one or more
# data-cat keys (data-cats attr, pipe-separated); the catch-all Pantry group must stay LAST.
$groupDefs = @(
  @{ label = 'Meat &amp; Poultry'; rx = 'Meat|Poultry|Seafood' },
  @{ label = 'Dairy &amp; Eggs';   rx = 'Dairy|Cheese|Egg' },
  @{ label = 'Produce';            rx = 'Fruit|Vegetable|Produce' },
  @{ label = 'Pantry &amp; More';  rx = '.' }
)
$groupKeys = @{}; foreach ($gd in $groupDefs) { $groupKeys[[string]$gd.label] = New-Object System.Collections.Generic.List[string] }
$allCatPairs = New-Object System.Collections.Generic.List[object]
foreach ($c in $cats) { $allCatPairs.Add(@{ key = [string]$c.key; label = [string]$c.label }) }
foreach ($rc in $riCats) { if (-not $weeklyLabelKey.ContainsKey($rc)) { $allCatPairs.Add(@{ key = ('ri:' + $rc); label = [string]$rc }) } }
foreach ($p in $allCatPairs) {
  foreach ($gd in $groupDefs) { if ($p.label -match $gd.rx) { $groupKeys[[string]$gd.label].Add([string]$p.key); break } }
}
[void]$sb.Append("<nav class='pg-filters' aria-label='Search and filter'>")
[void]$sb.Append("<input class='pg-search' id='pg-search' type='search' placeholder='Search items: eggs, chicken, coffee...' aria-label='Search items'>")
[void]$sb.Append("<div class='pg-pills'>")
[void]$sb.Append("<button class='pg-fbtn is-active' data-cat='all'>All</button>")
[void]$sb.Append("<button class='pg-fbtn pg-fbtn-sale' data-cat='sale' id='pg-sale-pill'>On sale</button>")
foreach ($gd in $groupDefs) {
  $keys = ($groupKeys[[string]$gd.label] -join '|')
  if ($keys) { [void]$sb.Append("<button class='pg-fbtn' data-cat='group' data-cats='" + (HtmlEnc $keys) + "'>" + $gd.label + "</button>") }
}
[void]$sb.Append("</div></nav>")

$totalCommodities = 0; $totalPrices = 0
foreach ($c in $cats) {
  [void]$sb.Append("<section class='pg-cat' data-cat='" + $c.key + "'><h2 class='pg-cath'>" + (HtmlEnc $c.label) + "</h2>")
  foreach ($cid in $c.commodities) {
    $r = $byId[[string]$cid]
    if (-not $r) { continue }
    $ranked = @($r.stores | Sort-Object per_unit)
    if ($ranked.Count -eq 0) { continue }
    $totalCommodities++
    $unit = [string]$r.unit
    [void]$sb.Append("<article class='pg-row' data-cat='" + $c.key + "'>")
    [void]$sb.Append("<div class='pg-rowhead'><label class='pg-pickl' title='Add to my shopping list'><input type='checkbox' class='pg-pick' aria-label='Add to my shopping list'></label><span class='pg-name'>" + (HtmlEnc $r.commodity) + "</span><span class='pg-unit'>" + (UnitLabel $unit) + "</span></div>")
    [void]$sb.Append("<div class='pg-stores'>")
    $i = 0
    foreach ($s in $ranked) {
      $totalPrices++
      $isBest = ($i -eq 0)
      $cls = 'pg-chip'; if ($isBest) { $cls += ' is-best' }
      $notes = @()
      if ($s.membership) { $notes += 'membership' }
      if ($s.bulk) { $notes += 'bulk' }
      $typeTag = if ([string]$s.type -eq 'sale') { "<span class='pg-tag pg-tag-sale'>sale</span>" } else { "<span class='pg-tag'>everyday</span>" }
      [void]$sb.Append("<div class='" + $cls + "' data-store=`"" + (HtmlEnc ([string]$s.store)) + "`" data-pu='" + ('{0:F4}' -f [double]$s.per_unit) + "'>")
      if ($isBest) { [void]$sb.Append("<span class='pg-best'>Cheapest</span>") }
      [void]$sb.Append("<span class='pg-store'>" + (HtmlEnc $shortName[[string]$s.store]) + "</span>")
      [void]$sb.Append("<span class='pg-price'>" + (Fmt-Price ([double]$s.per_unit) $unit) + "</span>")
      [void]$sb.Append("<span class='pg-meta'>" + $typeTag + ($(if ($notes.Count) { " <span class='pg-note2'>" + (HtmlEnc ($notes -join ', ')) + "</span>" } else { '' })) + "</span>")
      [void]$sb.Append((SaleBadge $s ([string]$s.store)))
      [void]$sb.Append((SeeLink ([string]$r.id) ([string]$s.store) ([string]$s.item) ([double]$s.per_unit) $unit))
      [void]$sb.Append("</div>")
      $i++
    }
    [void]$sb.Append("</div></article>")
  }
  [void]$sb.Append("</section>")
}

# ---- recipe-ingredient sections (below the weekly staples), rendered when recipe-board.json is present ----
if ($riDoc) {
  # Honest label: these are EVERYDAY (non-sale) shelf prices for recipe ingredients, verified periodically -
  # NOT this week's ad prices (unlike the staples above). Date-stamp so nothing reads as fresher than it is.
  # date the FLOORS were verified = the monthly baseline's mtime, NOT the live board's (the daily ad-sale
  # overlay rewrites recipe-board.json every morning, which would make this read "verified today" forever).
  $riDate = ''
  try { $riBase = Join-Path $OutDir 'recipe-board-everyday.json'; $riStamp = if (Test-Path $riBase) { $riBase } else { $riFile }; $riDate = ([datetime](Get-Item $riStamp).LastWriteTime).ToString('MMM d, yyyy') } catch {}
  [void]$sb.Append("<div class='pg-refnote'>The prices below are <strong>regular shelf prices</strong> for recipe ingredients (checked " + (HtmlEnc $riDate) + ", re-checked monthly). When one goes on sale in a weekly ad, the <strong>sale price shows automatically</strong> with its end date. Ranked cheapest first, same as above.</div>")
  foreach ($rc in $riCats) {
    $riKey = RiCatKey $rc
    [void]$sb.Append("<section class='pg-cat' data-cat='" + (HtmlEnc $riKey) + "'><h2 class='pg-cath'>" + (HtmlEnc $rc) + "</h2>")
    foreach ($r in ($riDoc.comparison | Where-Object { [string]$_.category -eq $rc })) {
      $ranked = @($r.stores | Sort-Object per_unit)
      if ($ranked.Count -eq 0) { continue }
      $totalCommodities++
      $unit = [string]$r.unit
      [void]$sb.Append("<article class='pg-row' data-cat='" + (HtmlEnc $riKey) + "'>")
      [void]$sb.Append("<div class='pg-rowhead'><label class='pg-pickl' title='Add to my shopping list'><input type='checkbox' class='pg-pick' aria-label='Add to my shopping list'></label><span class='pg-name'>" + (HtmlEnc $r.commodity) + "</span><span class='pg-unit'>" + (UnitLabel $unit) + "</span></div>")
      [void]$sb.Append("<div class='pg-stores'>")
      $i = 0
      foreach ($s in $ranked) {
        $totalPrices++
        $isBest = ($i -eq 0)
        $cls = 'pg-chip'; if ($isBest) { $cls += ' is-best' }
        $notes = @()
        if ([string]$s.store -eq "Sam's Club") { $notes += 'membership' }
        if ($s.bulk) { $notes += 'bulk' }
        [void]$sb.Append("<div class='" + $cls + "' data-store=`"" + (HtmlEnc ([string]$s.store)) + "`" data-pu='" + ('{0:F4}' -f [double]$s.per_unit) + "'>")
        if ($isBest) { [void]$sb.Append("<span class='pg-best'>Cheapest</span>") }
        [void]$sb.Append("<span class='pg-store'>" + (HtmlEnc $shortName[[string]$s.store]) + "</span>")
        [void]$sb.Append("<span class='pg-price'>" + (Fmt-Price ([double]$s.per_unit) $unit) + "</span>")
        $riTag = if ([string]$s.type -eq 'sale') { "<span class='pg-tag pg-tag-sale'>sale</span>" } else { "<span class='pg-tag'>everyday</span>" }
        [void]$sb.Append("<span class='pg-meta'>" + $riTag + ($(if ($notes.Count) { " <span class='pg-note2'>" + (HtmlEnc ($notes -join ', ')) + "</span>" } else { '' })) + "</span>")
        [void]$sb.Append((SaleBadge $s ([string]$s.store)))
        [void]$sb.Append((SeeLink ([string]$r.id) ([string]$s.store) ([string]$s.item) ([double]$s.per_unit) $unit))
        [void]$sb.Append("</div>")
        $i++
      }
      [void]$sb.Append("</div></article>")
    }
    [void]$sb.Append("</section>")
  }
}

# membership CTA: this page is the site's best proof asset - close the loop from free prices to the $1 offer.
[void]$sb.Append("<div class='pg-cta'><h3>The prices are free. The dinners are about a dollar a month.</h3>")
[void]$sb.Append("<p>This board tells you where the cheap groceries are. The membership turns them into dinners: 113 meal-prep recipes costed to the plate, most at $2 to $3 a serving, plus the 52-week money program. It pays for itself in one grocery run.</p>")
[void]$sb.Append("<p class='pg-cta-row'><a class='pg-cta-btn' href='#/portal/signup'>Join for $1 a month &rarr;</a> <a class='pg-cta-alt' href='/meal-prep-recipes/'>or browse a few recipes free</a></p>")
[void]$sb.Append("<p class='pg-cta-fine'>Not a trial, not an intro rate. $1 a month is the whole price, and it gets everything.</p></div>")
# transparency strip lives down here with the fine print, not above the prices
[void]$sb.Append($statusHtml)
[void]$sb.Append("<footer class='pg-foot'><p>" + $totalCommodities + " staples compared across Omaha stores &middot; " + $totalPrices + " live prices &middot; week of " + (HtmlEnc $week) + ".</p>")
[void]$sb.Append("<p class='pg-disc'>Prices change often and can vary by store; we verify against each store's own ad or site, never a delivery app. This is a free weekly guide, not a guarantee of in-store price.</p></footer>")
# ---- trip planner: floating selection bar + store-split panel (fixed position; populated by JS) ----
# bottom floating bar stays for redundancy; its button scrolls back up to the always-visible planner box
[void]$sb.Append("<div class='pg-tripbar' id='pg-tripbar' hidden><span class='pg-trip-n' id='pg-trip-n'>0 items</span><button class='pg-trip-plan' id='pg-trip-plan'>Plan my trip &uarr;</button><button class='pg-trip-clear' id='pg-trip-clear'>Clear</button></div>")
[void]$sb.Append("</div>")
$body = $sb.ToString()

$css = @'
<style>
/* TOOL, not article: hide the blog chrome (byline/read-time/excerpt) and the financial-advice disclaimer
   on this page only (this CSS ships inside the page embed). A grocery list is not financial advice. */
.gh-article-header .gh-article-meta,.gh-article-header .gh-article-author,.gh-article-header [class*="byline"],.gh-article-excerpt,.mts-disclaimer{display:none !important}
/* brand harmony: navy ink + gold accents to match the site; green stays ONLY where it means savings */
/* min-width:0 is LOAD-BEARING: pg-wrap sits in the theme's CSS grid column, whose items default to
   min-width:auto - the non-wrapping pills row's intrinsic width (~526px) inflated the whole board past
   phone viewports and everything clipped at the right edge. */
.pg-wrap{min-width:0;max-width:100%;--ink:#16263F;--green:#10794e;--green-d:#0c5c3b;--green-t:#e6f5ec;--mut:#5a6862;--bd:#e2e6ec;--amber:#8a6d1f;--amber-t:#f8f0d8;
  max-width:1060px;margin:0 auto;padding:8px 16px 44px;color:var(--ink);
  font-family:inherit,-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased;font-variant-numeric:tabular-nums;font-size:1.6rem}
.pg-wrap *{box-sizing:border-box}
.pg-suggest{font-size:.98em;margin:.6em 0 0;color:var(--ink)}
.pg-suggest a{color:var(--green-d);font-weight:700;text-decoration:none;border-bottom:2px solid var(--green-t)}
.pg-suggest a:hover{border-bottom-color:var(--green)}
.pg-head h1{font-size:2em;line-height:1.12;margin:.1em 0 .12em;color:var(--ink);text-wrap:balance;letter-spacing:-.01em}
.pg-sub{font-size:1.08em;line-height:1.4;color:var(--mut);margin:.2em 0 .5em;max-width:60ch}
.pg-note{font-size:.83em;color:var(--mut);opacity:.85;margin:.2em 0 0;max-width:66ch}
/* scoreboard */
.pg-board{margin:20px 0 6px;padding:15px 16px 14px;border:1px solid var(--bd);border-radius:14px;background:var(--green-t)}
.pg-board-h{display:block;font-size:.7em;font-weight:700;text-transform:uppercase;letter-spacing:.09em;color:var(--green-d);margin-bottom:11px}
.pg-board-row{display:flex;flex-wrap:wrap;gap:10px}
.pg-score{flex:1 1 auto;min-width:96px;display:flex;flex-direction:column;align-items:center;gap:1px;padding:9px 8px;border-radius:10px;background:#fff;border:1px solid var(--bd)}
.pg-score.is-lead{background:var(--green);border-color:var(--green)}
.pg-score-n{font-size:1.55em;font-weight:800;line-height:1;color:var(--ink)}
.pg-score.is-lead .pg-score-n{color:#fff}
.pg-score-s{font-size:.74em;font-weight:600;color:var(--mut)}
.pg-score.is-lead .pg-score-s{color:#d9f2e5}
/* store status strip */
.pg-status{margin:12px 0 6px;padding:13px 15px 14px;border:1px solid var(--bd);border-radius:12px;background:#fbfcfb}
.pg-status-h{display:block;font-size:.7em;font-weight:700;text-transform:uppercase;letter-spacing:.08em;color:var(--mut);margin-bottom:11px}
.pg-status-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(148px,1fr));gap:9px}
.pg-st{display:flex;flex-direction:column;gap:2px;padding:9px 11px;border-radius:9px;background:#fff;border:1px solid var(--bd)}
.pg-st-store{font-size:.87em;font-weight:700;color:var(--ink)}
.pg-st-ad{font-size:.74em;font-weight:600;color:var(--green-d)}
.pg-st-upd{font-size:.7em;color:var(--mut)}
/* filters */
.pg-filters{position:sticky;top:0;z-index:5;display:flex;flex-direction:column;gap:9px;padding:12px 0 10px;margin-bottom:6px;background:rgba(255,255,255,.96);backdrop-filter:blur(8px);border-bottom:1px solid var(--bd)}
.pg-search{width:100%;max-width:460px;padding:10px 16px;font-size:1em;font-family:inherit;color:var(--ink);border:1.5px solid var(--bd);border-radius:999px;background:#fff;outline:none}
.pg-search:focus{border-color:var(--green)}
.pg-pills{display:flex;flex-wrap:wrap;gap:8px}
.pg-fbtn-sale{color:#b23b2e;border-color:rgba(178,59,46,.35)}
.pg-fbtn-sale.is-active{background:#b23b2e;border-color:#b23b2e;color:#fff}
.pg-cath-n{font-weight:400;font-size:.78em;color:var(--mut);margin-left:8px;letter-spacing:0}
.pg-fbtn{border:1px solid var(--bd);background:#fff;color:var(--mut);border-radius:999px;padding:7px 16px;font-size:.9em;font-weight:600;cursor:pointer;transition:.14s;font-family:inherit}
.pg-fbtn:hover{border-color:var(--green);color:var(--green-d)}
.pg-fbtn.is-active{background:var(--ink);border-color:var(--ink);color:#fff}
.pg-fbtn:focus-visible{outline:2px solid var(--green);outline-offset:2px}
.pg-toggle{display:inline-flex;align-items:center;gap:8px;margin:2px 0 12px;font-size:.9em;font-weight:600;color:var(--ink);cursor:pointer;flex-wrap:wrap}
.pg-toggle input{width:17px;height:17px;accent-color:var(--green);cursor:pointer;margin:0}
.pg-toggle-note{font-weight:500;font-size:.76em;color:var(--amber)}
/* sections + rows */
.pg-cath{font-family:Georgia,'Times New Roman',serif;font-size:1.22em;color:var(--ink);margin:26px 0 4px;padding-bottom:6px;border-bottom:2px solid var(--bd)}
.pg-refnote{margin:26px 0 4px;padding:9px 13px;font-size:.82em;line-height:1.4;color:var(--mut);background:var(--amber-t);border:1px solid var(--bd);border-radius:8px}
.pg-row{padding:15px 0 16px;border-bottom:1px solid #eef1ee}
.pg-rowhead{display:flex;align-items:baseline;gap:10px;margin-bottom:10px}
.pg-name{font-size:1.09em;font-weight:700;color:var(--ink)}
.pg-unit{font-size:.72em;color:var(--mut);opacity:.8;text-transform:uppercase;letter-spacing:.05em}
.pg-stores{display:flex;flex-wrap:wrap;gap:8px}
.pg-chip{position:relative;display:flex;flex-direction:column;gap:3px;min-width:118px;padding:10px 13px 9px;border:1px solid var(--bd);border-radius:11px;background:#fcfdfc}
.pg-chip.is-best{border-color:var(--green);background:var(--green-t);box-shadow:inset 0 0 0 1px var(--green)}
.pg-best{position:absolute;top:-9px;left:11px;background:var(--green);color:#fff;font-size:.6em;font-weight:700;letter-spacing:.06em;text-transform:uppercase;padding:2px 8px;border-radius:999px}
.pg-store{font-size:.8em;font-weight:600;color:var(--mut)}
.pg-chip.is-best .pg-store{color:var(--green-d)}
.pg-price{font-size:1.14em;font-weight:800;color:var(--ink);line-height:1.1}
.pg-meta{display:flex;align-items:center;gap:6px;flex-wrap:wrap;min-height:14px}
.pg-tag{font-size:.64em;color:var(--mut);text-transform:uppercase;letter-spacing:.04em}
.pg-tag-sale{color:#b23b2e;font-weight:700}
.pg-note2{font-size:.62em;color:var(--amber);background:var(--amber-t);padding:1px 6px;border-radius:5px;font-weight:600}
.pg-sale{display:inline-block;margin-top:4px;font-size:.62em;font-weight:700;color:#b23b2e;background:rgba(178,59,46,.09);border:1px solid rgba(178,59,46,.22);padding:1px 6px;border-radius:5px;white-space:nowrap}
.pg-see{margin-top:5px;font-size:.68em;font-weight:700;color:var(--green-d);text-decoration:none;border-top:1px dotted var(--bd);padding-top:5px}
.pg-itemname{display:block;margin-top:5px;font-size:.66em;font-weight:500;color:var(--mut);border-top:1px dotted var(--bd);padding-top:5px;line-height:1.3}
.pg-see:hover{text-decoration:underline}
.pg-chip.is-best .pg-see{color:var(--green-d)}
.pg-cta{margin:34px 0 8px;padding:22px 24px;border-radius:14px;background:var(--green-t);border:1px solid var(--bd);text-align:center}
.pg-cta h3{margin:0 0 8px;font-size:1.28em;color:var(--ink);letter-spacing:-.01em}
.pg-cta p{margin:0 auto;max-width:58ch;font-size:.95em;line-height:1.55;color:var(--ink)}
.pg-cta-row{margin-top:14px !important}
.pg-cta-btn{display:inline-block;background:var(--green);color:#fff !important;font-weight:700;font-size:1em;padding:11px 26px;border-radius:999px;text-decoration:none}
.pg-cta-btn:hover{background:var(--green-d)}
.pg-cta-alt{display:inline-block;margin-left:12px;color:var(--green-d);font-weight:600;font-size:.9em}
.pg-cta-fine{margin-top:10px !important;font-size:.8em !important;color:var(--mut) !important}
.pg-foot{margin-top:28px;font-size:.8em;color:var(--mut)}
.pg-disc{font-size:.72em;margin-top:6px;opacity:.8}
.pg-cat.pg-hide,.pg-row.pg-hide{display:none}
.pg-ri-intro{margin:36px 0 2px;padding:0}
.pg-ri-h2{font-size:1.5em;margin:0 0 3px;color:var(--ink);border:none;padding:0;letter-spacing:-.01em}
.pg-ri-sub2{font-size:.9em;color:var(--mut);margin:0;max-width:66ch;line-height:1.4}
@media(max-width:560px){.pg-wrap{font-size:1.4rem}.pg-head h1{font-size:1.55em}.pg-chip{min-width:calc(50% - 4px);flex:1 1 calc(50% - 4px)}.pg-score{min-width:calc(33% - 7px)}
/* phone: pills become one horizontally-scrollable row instead of a 3-row wall.
   contain:inline-size is LOAD-BEARING: without it the row's intrinsic width (~526px of pills) propagates
   up through the flex/grid chain and inflates the whole board past the phone viewport (min-width:0 alone
   does NOT stop the intrinsic-size contribution; percentage max-widths are ignored in intrinsic sizing). */
.pg-pills{flex-wrap:nowrap;overflow-x:auto;-webkit-overflow-scrolling:touch;padding-bottom:4px;scrollbar-width:none;min-width:0;max-width:100%;contain:inline-size}
.pg-pills::-webkit-scrollbar{display:none}
.pg-fbtn{white-space:nowrap;flex:0 0 auto}}
/* Desktop readability: bump the readable text ~13% on real screens; phones/small tablets keep the tighter sizes above. */
@media(min-width:700px){
.pg-sub{font-size:1.2em}.pg-cath{font-size:1.32em}
.pg-name{font-size:1.24em}.pg-unit{font-size:.8em}
.pg-chip{min-width:132px;padding:12px 15px 11px}.pg-price{font-size:1.3em}.pg-store{font-size:.9em}
.pg-tag{font-size:.72em}.pg-note2{font-size:.7em}.pg-sale{font-size:.7em}.pg-see{font-size:.78em}.pg-itemname{font-size:.76em}
.pg-st-store{font-size:.97em}.pg-st-ad{font-size:.82em}.pg-st-upd{font-size:.78em}
.pg-fbtn{font-size:1em}.pg-toggle{font-size:1em}.pg-refnote{font-size:.92em}.pg-ri-sub2{font-size:1em}
}
/* ---- trip planner ---- */
.pg-pickl{display:inline-flex;align-items:center;margin-right:6px}
.pg-pick{width:18px;height:18px;accent-color:var(--green);cursor:pointer;margin:0}
.pg-tripbar{position:fixed;left:50%;transform:translateX(-50%);bottom:18px;z-index:60;display:flex;align-items:center;gap:12px;background:var(--ink);color:#fff;border-radius:999px;padding:10px 18px;box-shadow:0 8px 28px rgba(0,0,0,.28);max-width:calc(100vw - 20px)}
.pg-tripbar[hidden]{display:none}
.pg-trip-n{font-weight:700;font-size:.95em;white-space:nowrap}
.pg-trip-plan{background:#E2A43C;color:#16263F;font-weight:700;border:none;border-radius:999px;padding:8px 16px;cursor:pointer;font-family:inherit;font-size:.9em;white-space:nowrap}
.pg-trip-plan:hover{background:#d29632}
.pg-trip-clear{background:transparent;color:#c8d2df;border:none;cursor:pointer;font-family:inherit;font-size:.85em;text-decoration:underline}
.pg-tripbox{margin:14px 0 6px;padding:16px 18px 14px;border:1.5px solid var(--ink);border-radius:14px;background:#fff}
.pg-tripbox h3{font-family:Georgia,'Times New Roman',serif;font-size:1.18em;color:var(--ink);margin:0 0 5px}
.pg-tripbox-sub{font-size:.92em;color:var(--mut);margin:0;line-height:1.5;max-width:64ch}
.pg-tripbox-sub[hidden]{display:none}
.pg-tripbox-n{font-size:.95em;color:var(--ink);margin:2px 0 10px}
#pg-tripbox-body[hidden]{display:none}
.pg-plan-kbtns{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:12px}
.pg-plan-k.is-active{background:var(--ink) !important;color:#fff !important;border-color:var(--ink) !important}
.pg-plan-sum{font-size:.95em;color:var(--ink);margin:4px 0 8px}
.pg-plan-store{margin:10px 0;padding:10px 12px;background:var(--green-t);border-radius:9px}
.pg-plan-store p{margin:4px 0 0;font-size:.88em;color:var(--ink);line-height:1.45}
.pg-plan-store span{color:var(--mut);font-weight:600}
.pg-plan-un{font-size:.85em;color:var(--amber);margin:8px 0 0}
.pg-plan-note{font-size:.75em;color:var(--mut);margin:10px 0 0}
@media(prefers-reduced-motion:reduce){.pg-fbtn{transition:none}}
</style>
'@

$js = @'
<script>
(function(){
  // ---- unified filtering: one state (active pill + search query), one apply pass ----
  var state={pill:'all',cats:null,q:''};
  function applyFilters(){
    var q=state.q.toLowerCase().trim();
    document.querySelectorAll('.pg-cat').forEach(function(sec){
      var secCat=sec.getAttribute('data-cat')||'';
      var vis=0;
      sec.querySelectorAll('.pg-row').forEach(function(row){
        var show;
        if(q){ var nm=row.querySelector('.pg-name'); show=nm && nm.textContent.toLowerCase().indexOf(q)>-1; }
        else if(state.pill==='sale'){ show=!!row.querySelector('.pg-tag-sale'); }
        else if(state.pill==='all'){ show=true; }
        else { show=state.cats && state.cats.indexOf(secCat)>-1; }
        row.classList.toggle('pg-hide',!show); if(show){vis++;}
      });
      sec.classList.toggle('pg-hide',vis===0);
    });
    var rn=document.querySelector('.pg-refnote'); if(rn){ rn.classList.toggle('pg-hide', !!q || state.pill==='sale'); }
  }
  var btns=document.querySelectorAll('.pg-fbtn');
  btns.forEach(function(b){
    b.addEventListener('click',function(){
      btns.forEach(function(x){x.classList.remove('is-active')});
      b.classList.add('is-active');
      var cat=b.getAttribute('data-cat');
      state.pill=cat;
      state.cats=(cat==='group')?(b.getAttribute('data-cats')||'').split('|'):null;
      if(cat==='group'){state.pill='group';}
      var s=document.getElementById('pg-search'); if(s && s.value){ s.value=''; state.q=''; }
      applyFilters();
    });
  });
  // search-as-you-type across all 89 items; typing overrides the pill filter
  var search=document.getElementById('pg-search');
  if(search){
    search.addEventListener('input',function(){
      state.q=search.value;
      if(state.q){ btns.forEach(function(x){x.classList.remove('is-active')}); }
      else { var all=document.querySelector(".pg-fbtn[data-cat='all']"); btns.forEach(function(x){x.classList.remove('is-active')}); if(all){all.classList.add('is-active');} state.pill='all'; state.cats=null; }
      applyFilters();
    });
  }
  // fill the On-sale pill with the live count + stamp item counts into section headers
  var saleRows=0;
  document.querySelectorAll('.pg-row').forEach(function(r){ if(r.querySelector('.pg-tag-sale')){saleRows++;} });
  var sp=document.getElementById('pg-sale-pill'); if(sp){ sp.textContent='On sale ('+saleRows+')'; }
  document.querySelectorAll('.pg-cat').forEach(function(sec){
    var n=sec.querySelectorAll('.pg-row').length, h=sec.querySelector('.pg-cath');
    if(h && n){ var sp2=document.createElement('span'); sp2.className='pg-cath-n'; sp2.textContent='\u00B7 '+n+(n===1?' item':' items'); h.appendChild(sp2); }
  });
  // hide Sam's Club: drop its chips, then re-flag the cheapest per row + recount the scoreboard
  var SAMS="Sam's Club";
  var tg=document.getElementById('pg-hidesams');
  function recompute(){
    var hide=tg.checked, wins={};
    document.querySelectorAll('.pg-row').forEach(function(row){
      var chips=[].slice.call(row.querySelectorAll('.pg-chip')), first=null;
      chips.forEach(function(c){
        var h=hide && c.getAttribute('data-store')===SAMS;
        c.style.display=h?'none':'';
        c.classList.remove('is-best');
        var f=c.querySelector('.pg-best'); if(f){f.remove();}
        if(!h && !first){first=c;}
      });
      if(first){
        first.classList.add('is-best');
        var b=document.createElement('span'); b.className='pg-best'; b.textContent='Cheapest';
        first.insertBefore(b, first.firstChild);
        var st=first.getAttribute('data-store'); wins[st]=(wins[st]||0)+1;
      }
    });
    var maxw=0; for(var k in wins){ if(wins[k]>maxw){maxw=wins[k];} }
    document.querySelectorAll('.pg-score').forEach(function(cell){
      var st=cell.getAttribute('data-store'), n=wins[st]||0, sams=st===SAMS;
      cell.style.display=(hide&&sams)?'none':'';
      cell.querySelector('.pg-score-n').textContent=n;
      cell.classList.toggle('is-lead', !(hide&&sams) && n===maxw && n>0);
      cell.style.order=String(100-n);
    });
  }
  if(tg){ tg.addEventListener('change',recompute); }
  // ---- trip planner: pick items, choose store count, get the optimal split ----
  // Objective is UNIT-SAFE: sum over items of (best price within combo / global best price) - a
  // dimensionless ratio - because per-lb and per-dozen prices cannot be summed as dollars honestly.
  function esc(s){ var d=document.createElement('span'); d.textContent=s; return d.innerHTML; }
  var tripSel={}, ridSeq=0;
  document.querySelectorAll('.pg-row').forEach(function(row){
    var rid='r'+(ridSeq++);
    var cb=row.querySelector('.pg-pick');
    if(!cb) return;
    cb.addEventListener('change',function(){
      if(cb.checked){
        var prices={};
        row.querySelectorAll('.pg-chip').forEach(function(c){
          var pu=parseFloat(c.getAttribute('data-pu')), st=c.getAttribute('data-store');
          if(st && pu>0 && (!(st in prices) || pu<prices[st])) prices[st]=pu;
        });
        tripSel[rid]={name:row.querySelector('.pg-name').textContent,prices:prices};
      } else { delete tripSel[rid]; }
      tripBar();
    });
  });
  function tripN(){ var n=0; for(var k in tripSel){n++;} return n; }
  var lastK=0;
  function tripBar(){
    var n=tripN(), bar=document.getElementById('pg-tripbar');
    if(bar){ document.getElementById('pg-trip-n').textContent=n+(n===1?' item':' items'); bar.hidden=(n===0); }
    var body=document.getElementById('pg-tripbox-body'), sub=document.getElementById('pg-tripbox-sub'), cnt=document.getElementById('pg-tripbox-count');
    if(!body) return;
    body.hidden=(n===0);
    if(sub){ sub.hidden=(n>0); }
    if(cnt){ cnt.textContent=n+(n===1?' item':' items'); }
    if(n===0){ lastK=0; document.getElementById('pg-plan-out').innerHTML=''; var kb0=document.getElementById('pg-plan-kbtns'); kb0.innerHTML=''; kb0.removeAttribute('data-n'); return; }
    tripKBtns();
    // keep the plan LIVE: if a store count was already chosen, re-solve for the new selection
    if(lastK>0){ var ss=tripStores(); var kk=Math.min(lastK,ss.length); tripSolve(kk); tripMarkK(kk); }
  }
  function tripMarkK(k){ document.querySelectorAll('.pg-plan-k').forEach(function(x){ x.classList.toggle('is-active', x.getAttribute('data-k')===String(k)); }); }
  var tc=document.getElementById('pg-trip-clear');
  if(tc){ tc.addEventListener('click',function(){ document.querySelectorAll('.pg-pick').forEach(function(c){c.checked=false;}); tripSel={}; tripBar(); }); }
  var tp=document.getElementById('pg-trip-plan');
  if(tp){ tp.addEventListener('click',function(){ var b=document.getElementById('pg-tripbox'); if(b){ b.scrollIntoView({behavior:'smooth',block:'start'}); } }); }
  if(tg){ tg.addEventListener('change',function(){ if(tripN()>0){ tripKBtns(); if(lastK>0){ var ss=tripStores(); var kk=Math.min(lastK,ss.length); tripSolve(kk); tripMarkK(kk); } } }); }
  function tripStores(){
    var hide=tg&&tg.checked, set={};
    for(var k in tripSel){ for(var st in tripSel[k].prices){ if(!(hide&&st===SAMS)) set[st]=1; } }
    return Object.keys(set);
  }
  function tripKBtns(){
    var stores=tripStores(), kb=document.getElementById('pg-plan-kbtns');
    if(String(kb.getAttribute('data-n'))===String(stores.length)) return;   // store set unchanged: keep buttons + active state
    kb.setAttribute('data-n', String(stores.length));
    kb.innerHTML=''; document.getElementById('pg-plan-out').innerHTML='';
    for(var k=1;k<=stores.length;k++){
      (function(kk){
        var b=document.createElement('button'); b.className='pg-fbtn pg-plan-k'; b.type='button'; b.setAttribute('data-k',String(kk));
        b.textContent=kk+(kk===1?' store':' stores');
        b.addEventListener('click',function(){ tripSolve(kk); tripMarkK(kk); });
        kb.appendChild(b);
      })(k);
    }
  }
  function combosOf(arr,k){ var out=[]; (function rec(st,cur){ if(cur.length===k){out.push(cur.slice());return;} for(var i=st;i<arr.length;i++){cur.push(arr[i]);rec(i+1,cur);cur.pop();} })(0,[]); return out; }
  function tripSolve(k){
    var items=[]; for(var kk in tripSel){ items.push(tripSel[kk]); }
    var stores=tripStores();
    var gmin=[];
    items.forEach(function(it,i){ var m=null; stores.forEach(function(st){ var p=it.prices[st]; if(p>0&&(m===null||p<m)) m=p; }); gmin[i]=m; });
    var best=null;
    combosOf(stores,Math.min(k,stores.length)).forEach(function(cmb){
      var score=0;
      items.forEach(function(it,i){
        var m=null; cmb.forEach(function(st){ var p=it.prices[st]; if(p>0&&(m===null||p<m)) m=p; });
        if(m===null){ score+=10; } else if(gmin[i]>0){ score+=m/gmin[i]; }
      });
      if(best===null||score<best.score){ best={combo:cmb,score:score}; }
    });
    var byStore={}, uncovered=[], atBest=0;
    best.combo.forEach(function(st){ byStore[st]=[]; });
    items.forEach(function(it,i){
      var m=null,ms=null;
      best.combo.forEach(function(st){ var p=it.prices[st]; if(p>0&&(m===null||p<m)){m=p;ms=st;} });
      if(ms===null){ uncovered.push(it.name); return; }
      byStore[ms].push(it.name);
      if(m===gmin[i]){ atBest++; }
    });
    var html='<p class="pg-plan-sum">Your best '+best.combo.length+'-store trip gets the cheapest available price on <b>'+atBest+' of '+items.length+'</b> selected items.</p>';
    best.combo.slice().sort(function(a,b){return byStore[b].length-byStore[a].length;}).forEach(function(st){
      if(byStore[st].length===0) return;
      html+='<div class="pg-plan-store"><b>'+esc(st)+'</b> <span>('+byStore[st].length+(byStore[st].length===1?' item':' items')+')</span><p>'+byStore[st].map(esc).join(', ')+'</p></div>';
    });
    if(uncovered.length){ html+='<p class="pg-plan-un">Not sold at these stores: '+uncovered.map(esc).join(', ')+'</p>'; }
    document.getElementById('pg-plan-out').innerHTML=html;
    lastK=k;
  }
})();
</script>
'@

($css + $body + $js) | Set-Content $Out -Encoding UTF8
Write-Output ("deals page -> " + $Out + "  (" + $totalCommodities + " commodities, " + $totalPrices + " prices)")

