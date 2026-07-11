<#
  build-store-guide.ps1 - Renders "Shop Smart at Your Store": one self-contained HTML page for the
  shopper who goes to ONE store. A store picker (6 tabs, choice remembered in localStorage) shows,
  for the selected store: what to buy there (cheapest in town or within 2%), what's fine (within 10%),
  and what to skip (loses by more than 10%, with the cheapest alternative and the per-unit gap).

  Data: same board files as build-deals-page.ps1 (newest comparison-*.json, preferring the
  semantically-verified snapshot when at least as fresh) PLUS out\recipe-board.json (everyday
  recipe-ingredient prices). Rows the weekly board already covers are not duplicated from the
  recipe board (the weekly board carries this week's sale prices, so it wins).

  Usage: powershell -ExecutionPolicy Bypass -File build-store-guide.ps1 [-CompareFile <path>] [-Out <path>] [-Embed]
  -Embed suppresses the on-page <h1> (the Ghost post title is the H1 when embedded).
#>
param([string]$CompareFile = "", [string]$OutDir = "", [string]$Out = "", [switch]$Embed)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $CompareFile) {
  $cmpF = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1)
  $CompareFile = $cmpF.FullName
  # Prefer the semantically-verified board (wrong-product winners dropped/de-crowned by the verify pass) when
  # it is at least as fresh as the raw comparison; otherwise the raw comparison (fresher prices) wins.
  try { $wk = (Get-Content $cmpF.FullName -Raw | ConvertFrom-Json).week_of; $verF = Join-Path $OutDir ("verified-" + $wk + ".json"); if ((Test-Path $verF) -and ((Get-Item $verF).LastWriteTime -ge $cmpF.LastWriteTime)) { $CompareFile = $verF } } catch {}
}
if (-not $Out) { $Out = Join-Path $OutDir 'store-guide.html' }

$doc  = Get-Content $CompareFile -Raw | ConvertFrom-Json
$week = [string]$doc.week_of

$storeOrder = @('Hy-Vee','Aldi','Family Fare',"Baker's","Sam's Club",'Walmart')
$shortName  = @{ 'Hy-Vee'='Hy-Vee'; 'Aldi'='Aldi'; 'Family Fare'='Family Fare'; "Baker's"="Baker's"; "Sam's Club"="Sam's Club"; 'Walmart'='Walmart' }

# NOTE: must escape single quotes too - several attributes are single-quoted and store/brand
# names routinely contain apostrophes (Baker's, Sam's Club, Member's Mark).
function HtmlEnc([string]$s) { if ($null -eq $s) { return '' }; return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;' -replace "'",'&#39;') }

# format a per-unit price for display: cents for oz/fl oz, dollars otherwise (same as the price board).
# One divergence from the board: at $1/oz and up (spices), cents read badly ("5550&cent;/oz"), so we
# switch to dollars there.
function Fmt-Price([double]$v, [string]$unit) {
  switch ($unit) {
    'oz'    { if ($v -ge 1) { return ('$' + ('{0:N2}' -f $v) + '/oz') }; return ('' + [math]::Round($v*100) + '&cent;/oz') }
    'floz'  { if ($v -ge 1) { return ('$' + ('{0:N2}' -f $v) + '/fl oz') }; return ('' + [math]::Round($v*100) + '&cent;/fl oz') }
    'lb'    { return ('$' + ('{0:N2}' -f $v) + '/lb') }
    'gallon'{ return ('$' + ('{0:N2}' -f $v) + '/gal') }
    'dozen' { return ('$' + ('{0:N2}' -f $v) + '/dozen') }
    'each'  { return ('$' + ('{0:N2}' -f $v) + ' each') }
    default { return ('$' + ('{0:N2}' -f $v)) }
  }
}
# format a per-unit DIFFERENCE ("this much more here"): cents with one decimal for oz units
# (many oz gaps are under a cent and would round to a dishonest +0), dollars otherwise
function Fmt-Diff([double]$d, [string]$unit) {
  switch ($unit) {
    'oz'    { if ($d -ge 1) { return ('+$' + ('{0:N2}' -f $d) + '/oz') }; $c = [math]::Round($d*100, 1); if ($c -eq [math]::Floor($c)) { return ('+' + ('{0:N0}' -f $c) + '&cent;/oz') } else { return ('+' + ('{0:N1}' -f $c) + '&cent;/oz') } }
    'floz'  { if ($d -ge 1) { return ('+$' + ('{0:N2}' -f $d) + '/fl oz') }; $c = [math]::Round($d*100, 1); if ($c -eq [math]::Floor($c)) { return ('+' + ('{0:N0}' -f $c) + '&cent;/fl oz') } else { return ('+' + ('{0:N1}' -f $c) + '&cent;/fl oz') } }
    'lb'    { return ('+$' + ('{0:N2}' -f $d) + '/lb') }
    'gallon'{ return ('+$' + ('{0:N2}' -f $d) + '/gal') }
    'dozen' { return ('+$' + ('{0:N2}' -f $d) + '/dozen') }
    'each'  { return ('+$' + ('{0:N2}' -f $d) + ' each') }
    default { return ('+$' + ('{0:N2}' -f $d)) }
  }
}

# ---- category lookup for the weekly board (categories.json maps commodity ids to sections) ----
$idCat = @{}
$catFile = Join-Path $root 'categories.json'
if (Test-Path $catFile) {
  $cats = (Get-Content $catFile -Raw | ConvertFrom-Json).categories
  foreach ($c in $cats) { foreach ($cid in $c.commodities) { $idCat[[string]$cid] = [string]$c.label } }
}
# friendly lowercase phrases for the verdict line ("mostly produce")
$catPhrase = @{
  'Meat & Poultry'='meat'; 'Fruit'='produce'; 'Vegetables'='produce'; 'Produce'='produce';
  'Dairy & Eggs'='dairy'; 'Cheese & Dairy'='dairy'; 'Dairy & Cheese'='dairy'; 'Dairy'='dairy';
  'Pantry & Beverages'='pantry staples'; 'Pasta, Rice & Grains'='pantry staples';
  'Spices & Baking'='spices and baking'; 'Sauces & Condiments'='sauces and condiments';
  'Beans & Canned'='canned goods'; 'Canned & Jarred'='canned goods';
  'Beverages'='drinks'; 'Frozen'='frozen foods'; 'Oils'='cooking oils'
}
function CatPhrase([string]$label) {
  if ($catPhrase.ContainsKey($label)) { return $catPhrase[$label] }
  if (-not $label) { return 'everyday items' }
  return ($label.ToLower() -replace ' & ',' and ')
}

# ---- merge the two boards into one row list ----
# each row: @{ id; name; unit; cat; source('weekly'/'recipe'); prices = @{ store -> @{pu; type; membership; bulk} } }
$rows = @()
$seen = @{}
foreach ($r in $doc.comparison) {
  $pr = @{}
  foreach ($s in $r.stores) {
    $st = [string]$s.store; $pu = [double]$s.per_unit
    if ($pu -le 0) { continue }
    if ((-not $pr.ContainsKey($st)) -or ($pu -lt $pr[$st].pu)) {
      $pr[$st] = @{ pu = $pu; type = [string]$s.type; membership = [bool]$s.membership; bulk = [bool]$s.bulk }
    }
  }
  if ($pr.Count -eq 0) { continue }
  $cat = ''; if ($idCat.ContainsKey([string]$r.id)) { $cat = $idCat[[string]$r.id] }
  $rows += ,@{ id = [string]$r.id; name = [string]$r.commodity; unit = [string]$r.unit; cat = $cat; source = 'weekly'; prices = $pr }
  $seen[[string]$r.id] = $true
}
$riFile = Join-Path $OutDir 'recipe-board.json'
$riCount = 0
if (Test-Path $riFile) {
  $riDoc = Get-Content $riFile -Raw | ConvertFrom-Json
  foreach ($r in $riDoc.comparison) {
    if ($seen.ContainsKey([string]$r.id)) { continue }   # the weekly board (with sale prices) wins on overlap
    $pr = @{}
    foreach ($s in $r.stores) {
      $st = [string]$s.store; $pu = [double]$s.per_unit
      if ($pu -le 0) { continue }
      $mem = ($st -eq "Sam's Club")   # recipe-board rows carry no membership flag; Sam's is the only membership store
      if ((-not $pr.ContainsKey($st)) -or ($pu -lt $pr[$st].pu)) {
        $pr[$st] = @{ pu = $pu; type = [string]$s.type; membership = $mem; bulk = [bool]$s.bulk }
      }
    }
    if ($pr.Count -eq 0) { continue }
    $rows += ,@{ id = [string]$r.id; name = [string]$r.commodity; unit = [string]$r.unit; cat = [string]$r.category; source = 'recipe'; prices = $pr }
    $riCount++
  }
}

# ---- classify every row for every store ----
# buy  = this store is cheapest in town, or within 2% of cheapest
# fine = within 10% of cheapest
# skip = more than 10% over the cheapest store
$storeData = [ordered]@{}
foreach ($st in $storeOrder) { $storeData[$st] = @{ buy = @(); fine = @(); skip = @(); wins = 0; winCats = @{} } }
foreach ($row in $rows) {
  # cheapest across all stores on this row (deterministic tie-break: storeOrder)
  $minPu = $null
  foreach ($st in $row.prices.Keys) { $pu = $row.prices[$st].pu; if (($null -eq $minPu) -or ($pu -lt $minPu)) { $minPu = $pu } }
  $minStore = $null
  foreach ($st in $storeOrder) { if ($row.prices.ContainsKey($st) -and ($row.prices[$st].pu -le ($minPu + 0.00001))) { $minStore = $st; break } }
  foreach ($st in $storeOrder) {
    if (-not $row.prices.ContainsKey($st)) { continue }   # store doesn't carry it: not listed at all
    $p = $row.prices[$st]
    $gap = 0.0; if ($minPu -gt 0) { $gap = ($p.pu - $minPu) / $minPu }
    $entry = @{ row = $row; pu = $p.pu; type = $p.type; membership = $p.membership; bulk = $p.bulk
                minPu = $minPu; minStore = $minStore; gap = $gap; diff = ($p.pu - $minPu)
                only = ($row.prices.Count -eq 1); outright = ($st -eq $minStore) }
    if ($gap -le 0.02) {
      $storeData[$st].buy += ,$entry
      if ($entry.outright) {
        $storeData[$st].wins++
        # count by merged PHRASE, not raw label, so Fruit + Vegetables + Produce pool as 'produce'
        $cl = CatPhrase ([string]$row.cat)
        if (-not $storeData[$st].winCats.ContainsKey($cl)) { $storeData[$st].winCats[$cl] = 0 }
        $storeData[$st].winCats[$cl]++
      }
    } elseif ($gap -le 0.10) {
      $storeData[$st].fine += ,$entry
    } else {
      $storeData[$st].skip += ,$entry
    }
  }
}

# ---- per-store verdict line ----
function Verdict([string]$st) {
  $d = $storeData[$st]
  $w = $d.wins; $nb = @($d.buy).Count; $nf = @($d.fine).Count; $ns = @($d.skip).Count
  # dominant category among outright wins: 'mostly X' when it truly dominates (40%+),
  # 'led by X' when it merely leads (25%+). Never named on fewer than 3 winning items.
  $mostly = ''
  if ($w -ge 3) {
    $topCat = ''; $topN = 0
    foreach ($k in $d.winCats.Keys) { if ($d.winCats[$k] -gt $topN) { $topN = $d.winCats[$k]; $topCat = $k } }
    if ($topN -ge 3) {
      if ($topN * 100 -ge $w * 40) { $mostly = ', mostly ' + $topCat }
      elseif ($topN * 100 -ge $w * 25) { $mostly = ', led by ' + $topCat }
    }
  }
  $itemsWord = 'items'; if ($w -eq 1) { $itemsWord = 'item' }
  if ($w -gt 0) {
    $v = (HtmlEnc $shortName[$st]) + ' wins ' + $w + ' ' + $itemsWord + ' this week' + $mostly + '.'
    $near = $nb - $w
    if ($near -gt 0) { $v += ' It ties the best price on ' + $near + ' more.' }
  } else {
    $v = (HtmlEnc $shortName[$st]) + ' does not win a single item outright this week.'
    if ($nb -gt 0) { $v += ' It does tie the best price on ' + $nb + '.' }
  }
  if ($ns -gt 0) { $v += ' Fair on ' + $nf + ', overpriced on ' + $ns + '.' }
  elseif ($nf -gt 0) { $v += ' Fair on ' + $nf + ', overpriced on none.' }
  return $v
}

# small "(membership)" flag when we point a shopper at Sam's Club as the cheaper alternative
function MemFlag([string]$st) { if ($st -eq "Sam's Club") { return " <span class='sg-mem'>membership</span>" } else { return '' } }

# ---- render ----
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append("<div class='sg-wrap'>")
[void]$sb.Append("<header class='sg-head'>")
if (-not $Embed) { [void]$sb.Append("<h1>Shop Smart at Your Store</h1>") }
[void]$sb.Append("<p class='sg-sub'>Most of us shop at one store, not six. Pick yours below and we will show you what it does well, what is fair, and what it quietly overcharges for this week. Buy the winners here, and save the losers for another trip.</p>")
[void]$sb.Append("<p class='sg-note'>Built from the same verified prices as our <a href='/omaha-grocery-prices/'>weekly Omaha price board</a>: this week's ad prices for the staples, regular shelf prices for recipe ingredients. Your choice is saved on this device.</p>")
[void]$sb.Append("</header>")

# store picker tabs
[void]$sb.Append("<nav class='sg-tabs' aria-label='Pick your store'>")
foreach ($st in $storeOrder) {
  [void]$sb.Append("<button class='sg-tab' type='button' data-store=`"" + (HtmlEnc $st) + "`">" + (HtmlEnc $shortName[$st]) + "</button>")
}
[void]$sb.Append("</nav>")

$skipCap = 15
foreach ($st in $storeOrder) {
  $d = $storeData[$st]
  [void]$sb.Append("<section class='sg-sec' data-store=`"" + (HtmlEnc $st) + "`" hidden>")
  [void]$sb.Append("<p class='sg-verdict'>" + (Verdict $st) + "</p>")
  if ($st -eq "Sam's Club") {
    [void]$sb.Append("<p class='sg-caveat'>Heads up: Sam's Club prices need a paid membership, and most items come in bulk sizes. The per-unit price is real, but you will buy more of it at once.</p>")
  }

  # -- Buy these here --
  $buy = @($d.buy | Sort-Object { $_.gap }, { $_.row.name })
  [void]$sb.Append("<h2 class='sg-h sg-h-buy'>Buy these here <span class='sg-hn'>" + @($buy).Count + " items</span></h2>")
  if (@($buy).Count -eq 0) {
    [void]$sb.Append("<p class='sg-empty'>Nothing here is the best price in town this week. Check the fair list below.</p>")
  } else {
    [void]$sb.Append("<div class='sg-grid'>")
    foreach ($e in $buy) {
      [void]$sb.Append("<div class='sg-chip sg-chip-buy'>")
      [void]$sb.Append("<span class='sg-item'>" + (HtmlEnc $e.row.name) + "</span>")
      [void]$sb.Append("<span class='sg-price'>" + (Fmt-Price $e.pu $e.row.unit) + "</span>")
      if ($e.outright) {
        $tagTxt = 'Cheapest in town'
        if ($e.only) { $tagTxt = 'Only store we track it at' }
        [void]$sb.Append("<span class='sg-tag sg-tag-best'>" + $tagTxt + "</span>")
      } else {
        [void]$sb.Append("<span class='sg-tag sg-tag-tie'>Within 2% of the best</span>")
      }
      if ([string]$e.type -eq 'sale') { [void]$sb.Append("<span class='sg-sale'>sale</span>") }
      [void]$sb.Append("</div>")
    }
    [void]$sb.Append("</div>")
  }

  # -- Fine here --
  $fine = @($d.fine | Sort-Object { $_.gap }, { $_.row.name })
  [void]$sb.Append("<h2 class='sg-h sg-h-fine'>Fine here <span class='sg-hn'>" + @($fine).Count + " items, within 10% of the best</span></h2>")
  if (@($fine).Count -eq 0) {
    [void]$sb.Append("<p class='sg-empty'>Nothing lands in the close-enough zone this week.</p>")
  } else {
    [void]$sb.Append("<div class='sg-grid'>")
    foreach ($e in $fine) {
      $pct = [math]::Round($e.gap * 100)
      [void]$sb.Append("<div class='sg-chip'>")
      [void]$sb.Append("<span class='sg-item'>" + (HtmlEnc $e.row.name) + "</span>")
      [void]$sb.Append("<span class='sg-price'>" + (Fmt-Price $e.pu $e.row.unit) + "</span>")
      [void]$sb.Append("<span class='sg-gap'>" + (Fmt-Diff $e.diff $e.row.unit) + " &middot; " + $pct + "% over</span>")
      [void]$sb.Append("</div>")
    }
    [void]$sb.Append("</div>")
  }

  # -- Skip these here --
  $skip = @($d.skip | Sort-Object { $_.gap } -Descending)
  [void]$sb.Append("<h2 class='sg-h sg-h-skip'>Skip these here <span class='sg-hn'>" + @($skip).Count + " items, 10%+ over the best price</span></h2>")
  if (@($skip).Count -eq 0) {
    [void]$sb.Append("<p class='sg-empty'>Good news: nothing at this store is badly overpriced this week.</p>")
  } else {
    $shown = @($skip | Select-Object -First $skipCap)
    [void]$sb.Append("<div class='sg-skiplist'>")
    foreach ($e in $shown) {
      $pct = [math]::Round($e.gap * 100)
      [void]$sb.Append("<div class='sg-skiprow'>")
      [void]$sb.Append("<div class='sg-skipmain'><span class='sg-item'>" + (HtmlEnc $e.row.name) + "</span><span class='sg-skipdiff'>" + (Fmt-Diff $e.diff $e.row.unit) + " &middot; " + $pct + "% more</span></div>")
      [void]$sb.Append("<div class='sg-skipsub'><span class='sg-here'>" + (Fmt-Price $e.pu $e.row.unit) + " here</span> <span class='sg-vs'>vs</span> <span class='sg-there'>" + (Fmt-Price $e.minPu $e.row.unit) + " at " + (HtmlEnc $shortName[[string]$e.minStore]) + "</span>" + (MemFlag ([string]$e.minStore)) + "</div>")
      [void]$sb.Append("</div>")
    }
    $more = @($skip).Count - @($shown).Count
    if ($more -gt 0) { [void]$sb.Append("<p class='sg-more'>+" + $more + " more items run 10%+ over here. The full comparison is on the <a href='/omaha-grocery-prices/'>price board</a>.</p>") }
    [void]$sb.Append("</div>")
  }
  [void]$sb.Append("</section>")
}

$totalRows = @($rows).Count
[void]$sb.Append("<footer class='sg-foot'><p>" + $totalRows + " items compared across six Omaha stores &middot; week of " + (HtmlEnc $week) + ".</p>")
[void]$sb.Append("<p class='sg-disc'>Prices change often and can vary by store; we verify against each store's own ad or site, never a delivery app. This is a free weekly guide, not a guarantee of in-store price.</p></footer>")
[void]$sb.Append("</div>")
$body = $sb.ToString()

# default tab when nothing is saved yet: the store with the most outright wins this week
$defStore = $storeOrder[0]; $defWins = -1
foreach ($st in $storeOrder) { if ($storeData[$st].wins -gt $defWins) { $defWins = $storeData[$st].wins; $defStore = $st } }

$css = @'
<style>
/* TOOL, not article: hide the blog chrome and the financial-advice disclaimer on this page only. */
.gh-article-header .gh-article-meta,.gh-article-header .gh-article-author,.gh-article-header [class*="byline"],.gh-article-excerpt,.mts-disclaimer{display:none !important}
/* same palette as the price board: navy ink, savings green, amber for caveats */
.sg-wrap{min-width:0;max-width:1060px;--ink:#16263F;--green:#10794e;--green-d:#0c5c3b;--green-t:#e6f5ec;--mut:#5a6862;--bd:#e2e6ec;--amber:#8a6d1f;--amber-t:#f8f0d8;--red:#b23b2e;--red-t:rgba(178,59,46,.07);
  margin:0 auto;padding:8px 16px 44px;color:var(--ink);
  font-family:inherit,-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased;font-variant-numeric:tabular-nums;font-size:1.6rem}
.sg-wrap *{box-sizing:border-box}
.sg-head h1{font-size:2em;line-height:1.12;margin:.1em 0 .12em;color:var(--ink);text-wrap:balance;letter-spacing:-.01em}
.sg-sub{font-size:1.08em;line-height:1.4;color:var(--mut);margin:.2em 0 .5em;max-width:62ch}
.sg-note{font-size:.83em;color:var(--mut);opacity:.85;margin:.2em 0 0;max-width:66ch}
.sg-note a{color:var(--green-d);font-weight:600}
/* store picker: sticky pill tabs, one scrollable row on phones */
.sg-tabs{position:sticky;top:0;z-index:5;display:flex;flex-wrap:wrap;gap:8px;padding:12px 0 10px;margin-bottom:4px;background:rgba(255,255,255,.96);backdrop-filter:blur(8px);border-bottom:1px solid var(--bd)}
.sg-tab{border:1px solid var(--bd);background:#fff;color:var(--mut);border-radius:999px;padding:8px 18px;font-size:.95em;font-weight:700;cursor:pointer;transition:.14s;font-family:inherit;white-space:nowrap}
.sg-tab:hover{border-color:var(--green);color:var(--green-d)}
.sg-tab.is-active{background:var(--ink);border-color:var(--ink);color:#fff}
.sg-tab:focus-visible{outline:2px solid var(--green);outline-offset:2px}
.sg-sec[hidden]{display:none}
.sg-verdict{margin:16px 0 4px;padding:13px 16px;font-size:1.02em;font-weight:600;line-height:1.45;color:var(--ink);background:var(--green-t);border:1px solid var(--bd);border-radius:12px}
.sg-caveat{margin:8px 0 0;padding:9px 13px;font-size:.85em;line-height:1.45;color:var(--amber);background:var(--amber-t);border:1px solid var(--bd);border-radius:8px;max-width:72ch}
.sg-h{font-family:Georgia,'Times New Roman',serif;font-size:1.22em;color:var(--ink);margin:26px 0 10px;padding-bottom:6px;border-bottom:2px solid var(--bd)}
.sg-hn{font-family:inherit;font-weight:400;font-size:.68em;color:var(--mut);margin-left:8px;letter-spacing:0}
.sg-h-buy{border-bottom-color:var(--green)}
.sg-h-skip{border-bottom-color:rgba(178,59,46,.4)}
.sg-empty{font-size:.9em;color:var(--mut);margin:6px 0 0}
/* item chips */
.sg-grid{display:flex;flex-wrap:wrap;gap:8px}
.sg-chip{position:relative;display:flex;flex-direction:column;gap:3px;min-width:150px;max-width:100%;padding:10px 13px 9px;border:1px solid var(--bd);border-radius:11px;background:#fcfdfc}
.sg-chip-buy{border-color:var(--green);background:var(--green-t);box-shadow:inset 0 0 0 1px var(--green)}
.sg-item{font-size:.85em;font-weight:700;color:var(--ink);line-height:1.25}
.sg-price{font-size:1.14em;font-weight:800;color:var(--ink);line-height:1.1}
.sg-chip-buy .sg-price{color:var(--green-d)}
.sg-tag{font-size:.62em;font-weight:700;letter-spacing:.04em;text-transform:uppercase}
.sg-tag-best{color:var(--green-d)}
.sg-tag-tie{color:var(--mut)}
.sg-gap{font-size:.68em;font-weight:600;color:var(--mut)}
.sg-sale{position:absolute;top:-8px;right:10px;font-size:.58em;font-weight:700;letter-spacing:.05em;text-transform:uppercase;color:#fff;background:var(--red);padding:2px 8px;border-radius:999px}
/* skip list */
.sg-skiplist{display:flex;flex-direction:column;gap:8px}
.sg-skiprow{padding:10px 13px 9px;border:1px solid rgba(178,59,46,.25);border-radius:11px;background:var(--red-t)}
.sg-skipmain{display:flex;align-items:baseline;justify-content:space-between;gap:10px;flex-wrap:wrap}
.sg-skipdiff{font-size:.82em;font-weight:800;color:var(--red);white-space:nowrap}
.sg-skipsub{margin-top:3px;font-size:.78em;color:var(--mut)}
.sg-here{font-weight:700;color:var(--ink)}
.sg-vs{opacity:.7}
.sg-there{font-weight:700;color:var(--green-d)}
.sg-mem{font-size:.85em;color:var(--amber);background:var(--amber-t);padding:1px 6px;border-radius:5px;font-weight:600}
.sg-more{font-size:.82em;color:var(--mut);margin:6px 0 0}
.sg-more a{color:var(--green-d);font-weight:600}
.sg-foot{margin-top:32px;font-size:.8em;color:var(--mut)}
.sg-disc{font-size:.72em;margin-top:6px;opacity:.8}
@media(max-width:560px){.sg-wrap{font-size:1.4rem}.sg-head h1{font-size:1.55em}
.sg-chip{min-width:calc(50% - 4px);flex:1 1 calc(50% - 4px)}
/* phone: tabs become one horizontally-scrollable row. contain:inline-size is LOAD-BEARING (see the
   price board): without it the row's intrinsic width inflates the page past the phone viewport. */
.sg-tabs{flex-wrap:nowrap;overflow-x:auto;-webkit-overflow-scrolling:touch;padding-bottom:8px;scrollbar-width:none;min-width:0;max-width:100%;contain:inline-size}
.sg-tabs::-webkit-scrollbar{display:none}
.sg-tab{flex:0 0 auto}}
@media(min-width:700px){
.sg-sub{font-size:1.2em}.sg-h{font-size:1.32em}
.sg-chip{min-width:168px;padding:12px 15px 11px}.sg-price{font-size:1.3em}.sg-item{font-size:.95em}
.sg-tag{font-size:.7em}.sg-gap{font-size:.76em}
.sg-skipsub{font-size:.86em}.sg-skipdiff{font-size:.9em}.sg-verdict{font-size:1.1em}}
@media(prefers-reduced-motion:reduce){.sg-tab{transition:none}}
</style>
'@

$jsTop = "<script>(function(){var DEF=" + ("'" + ($defStore -replace "'","\'") + "'") + ";"
$js = $jsTop + @'

  var KEY='tcsg-store';
  var tabs=[].slice.call(document.querySelectorAll('.sg-tab'));
  var secs=[].slice.call(document.querySelectorAll('.sg-sec'));
  function show(store){
    var found=false;
    secs.forEach(function(s){ var hit=s.getAttribute('data-store')===store; s.hidden=!hit; if(hit){found=true;} });
    tabs.forEach(function(t){ t.classList.toggle('is-active', t.getAttribute('data-store')===store); t.setAttribute('aria-pressed', t.getAttribute('data-store')===store ? 'true':'false'); });
    if(!found && secs.length){ secs[0].hidden=false; }
  }
  tabs.forEach(function(t){
    t.addEventListener('click',function(){
      var st=t.getAttribute('data-store');
      show(st);
      try{ localStorage.setItem(KEY, st); }catch(e){}
    });
  });
  var start=DEF;
  try{ var saved=localStorage.getItem(KEY); if(saved){ var ok=tabs.some(function(t){return t.getAttribute('data-store')===saved;}); if(ok){ start=saved; } } }catch(e){}
  show(start);
})();</script>
'@

$html = $css + $body + $js
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($Out, $html, $utf8NoBom)

# ---- console report: per-store buy/fine/skip counts (plausibility check) ----
Write-Output ("store guide -> " + $Out + "  (" + $totalRows + " items: " + @($doc.comparison).Count + " weekly + " + $riCount + " recipe, week " + $week + ", default tab " + $defStore + ")")
Write-Output ("{0,-12} {1,5} {2,5} {3,5} {4,6}" -f 'Store','Buy','Fine','Skip','Wins')
foreach ($st in $storeOrder) {
  $d = $storeData[$st]
  Write-Output ("{0,-12} {1,5} {2,5} {3,5} {4,6}" -f $st, @($d.buy).Count, @($d.fine).Count, @($d.skip).Count, $d.wins)
}
