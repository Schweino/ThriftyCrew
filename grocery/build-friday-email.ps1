<#
  build-friday-email.ps1 - Renders the free Friday email promised by the board's capture:
  "Get this board every Friday, free. The updated prices and biggest drops, in your inbox before
  you shop the weekend."

  Writes out\friday-email.html (a content fragment; Ghost wraps it in the newsletter template) and
  out\friday-email.json (subject + a few counts, for the sender and for logging).

  DEGRADES HONESTLY. Some weeks have no qualifying price drop at all - the week of 2026-08-04 had
  zero, and the board correctly said "Prices held steady this week." An email whose entire promise is
  "biggest drops" must therefore still be worth opening on a flat week, so the staples table (always
  useful, always different) leads and the drops section says plainly when there is nothing to report.
  Never invent motion: the guards in lib\board-drops.ps1 exist precisely because a fabricated headline
  drop is worse than no headline at all.

  Usage: powershell -ExecutionPolicy Bypass -File build-friday-email.ps1
#>
param([string]$OutDir = '', [int]$TopDrops = 10)

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
. (Join-Path $root 'fmt-lib.ps1')
. (Join-Path $root '..\lib\board-drops.ps1')

$SITE = 'https://www.thriftycrew.com'

# ---- same board-file selection as build-deals-page.ps1, so the email can never quote a different
# board than the page it links to (prefer the semantically-verified snapshot when it is fresh). ----
$cmpF = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1)
$CompareFile = $cmpF.FullName
try {
  $wk0 = (Get-Content $cmpF.FullName -Raw | ConvertFrom-Json).week_of
  $verF = Join-Path $OutDir ("verified-" + $wk0 + ".json")
  if ((Test-Path $verF) -and ((Get-Item $verF).LastWriteTime -ge $cmpF.LastWriteTime)) { $CompareFile = $verF }
} catch {}

$doc  = Get-Content $CompareFile -Raw | ConvertFrom-Json
$week = [string]$doc.week_of
$byId = @{}; foreach ($r in $doc.comparison) { $byId[[string]$r.id] = $r }

$hist = Get-Content (Join-Path $root 'price-history.json') -Raw | ConvertFrom-Json
$histById = @{}; foreach ($c in $hist.commodities) { $histById[[string]$c.id] = $c }

function Esc { param([string]$t)
  if ($null -eq $t) { return '' }
  return $t.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}
# Prices go through fmt-lib's Fmt-Price, never a local formatter. Sub-cent unit prices are REAL on this
# board (cotton swabs are $0.0043 each) and a naive cents formatter renders them "0&cent;" - the exact
# bug fmt-lib was extracted to kill. It returns the unit too, so callers must not append one.
# NON-FOOD is excluded from the two "look at this" sections. Ranking records by absolute cheapness
# otherwise fills the email with cotton swabs, paper napkins and dryer sheets, because per-unit those
# always win. Nobody opens a grocery email for swabs.
$nonFoodKeys = @('household','personal','baby','pet')
# CORE is the weekly shop: meat, dairy, produce, bread, grains, frozen. Condiments, baking and spices are
# food, but they are restock-once-a-quarter food. Ranking purely by how deep a record is puts cayenne
# pepper and dried basil at the top of the email, because per-ounce spice pricing is the most volatile
# thing on the board. Core items win the slots; the long tail fills in only if core has nothing.
$coreKeys = @('meat','dairy','fruit','veg','bakery','grains','frozen')
$nonFood = @{}; $core = @{}
try {
  foreach ($c in (Get-Content (Join-Path $root 'categories.json') -Raw | ConvertFrom-Json).categories) {
    $k = [string]$c.key
    if ($nonFoodKeys -contains $k) { foreach ($cid in $c.commodities) { $nonFood[[string]$cid] = $true } }
    if ($coreKeys    -contains $k) { foreach ($cid in $c.commodities) { $core[[string]$cid]    = $true } }
  }
} catch { throw "categories.json unreadable - refusing to build an email that cannot tell food from dryer sheets." }
if ($core.Count -eq 0) { throw "no core-category commodities resolved from categories.json - the category keys have drifted." }

# ---- THE STAPLES. A fixed, familiar list so the email reads the same shape every week and a reader
# can scan for the one line they came for. Anything missing from the board is skipped, never faked. ----
$stapleIds = @('eggs','milk','ground-beef-8020','chicken-breast','butter','bread','bananas','shredded-cheese','russet-potatoes','coffee')
$staples = @()
foreach ($id in $stapleIds) {
  $r = $byId[$id]; if (-not $r) { continue }
  $p = [double]$r.cheapest_price; if ($p -le 0) { continue }
  $staples += [pscustomobject]@{ label = [string]$r.commodity; price = $p; unit = [string]$r.unit; store = [string]$r.cheapest_store }
}

# ---- THE DROPS. One source with the board's masthead chip (lib\board-drops.ps1). ----
$drops = @(Get-BoardDrops -Comparison $doc.comparison -HistById $histById -Week $week) |
  Where-Object { -not $nonFood.ContainsKey($_.id) } | Select-Object -First $TopDrops
$drops = @($drops)

# ---- RECORD LOWS. A commodity whose cheapest price this week equals its all-time tracked low.
# Same broadly-priced floor as the drops, so a one-store oddity never headlines. ----
$records = @()
foreach ($r in $doc.comparison) {
  if ($nonFood.ContainsKey([string]$r.id)) { continue }
  $h = $histById[[string]$r.id]; if (-not $h -or -not $h.record_low) { continue }
  $p = [double]$r.cheapest_price; if ($p -le 0) { continue }
  if (@($r.stores | Where-Object { [double]$_.per_unit -gt 0 }).Count -lt 4) { continue }
  $rl = [double]$h.record_low.price; if ($rl -le 0) { continue }
  if ($p -le ($rl + 0.0001)) {
    # Rank by how far this sits below the item's OWN recent normal, not by absolute price. Sorting by
    # price is a category quirk generator - per unit, spices and paper goods always beat flour - and it
    # is what filled the first build with cotton swabs. Median of the prior weeks is the "normal".
    $prior = @($h.history | Where-Object { try { [datetime]$_.week_of -lt [datetime]$week } catch { $false } } |
                ForEach-Object { [double]$_.cheapest_price } | Where-Object { $_ -gt 0 } | Sort-Object)
    $depth = 0.0
    if (@($prior).Count -ge 2) {
      $med = @($prior)[[int]([math]::Floor(@($prior).Count / 2))]
      if ($med -gt 0) { $depth = ($med - $p) / $med }
    }
    $records += [pscustomobject]@{ label = [string]$r.commodity; price = $p; unit = [string]$r.unit; store = [string]$r.cheapest_store; depth = $depth; core = $core.ContainsKey([string]$r.id) }
  }
}
$records = @($records | Sort-Object @{Expression='core';Descending=$true}, @{Expression='depth';Descending=$true} | Select-Object -First 6)

# ---------------- render ----------------
$sb = New-Object System.Text.StringBuilder
$dateLong = ([datetime]$week).ToString('MMMM d')

[void]$sb.Append("<p>Here is where every staple is cheapest in Omaha this week, checked across seven stores. Sale prices end when the new ads drop Wednesday morning.</p>")

if ($staples.Count -gt 0) {
  [void]$sb.Append("<h3>The staples this week</h3>")
  [void]$sb.Append('<table style="width:100%;border-collapse:collapse"><tbody>')
  foreach ($s in $staples) {
    [void]$sb.Append('<tr>')
    [void]$sb.Append('<td style="padding:7px 0;border-bottom:1px solid #e7e2d4">' + (Esc $s.label) + '</td>')
    [void]$sb.Append('<td style="padding:7px 0;border-bottom:1px solid #e7e2d4;text-align:right;white-space:nowrap"><strong>' + (Fmt-Price $s.price $s.unit) + '</strong></td>')
    [void]$sb.Append('<td style="padding:7px 0 7px 14px;border-bottom:1px solid #e7e2d4;text-align:right;white-space:nowrap">' + (Esc $s.store) + '</td>')
    [void]$sb.Append('</tr>')
  }
  [void]$sb.Append('</tbody></table>')
}

[void]$sb.Append("<h3>Biggest drops</h3>")
if ($drops.Count -gt 0) {
  [void]$sb.Append('<ul>')
  foreach ($d in $drops) {
    [void]$sb.Append('<li><strong>' + (Esc $d.commodity) + '</strong> is down ' + [int][math]::Floor($d.pct*100) + '%, now ' + (Fmt-Price $d.price $d.unit) + ' at ' + (Esc $d.store) + '</li>')
  }
  [void]$sb.Append('</ul>')
} else {
  # An honest flat week. Saying so costs one line and buys the trust that makes the other 51 weeks land.
  [void]$sb.Append('<p>Nothing moved much this week. No staple dropped enough to be worth a special trip, so buy what you normally buy and save the gas.</p>')
}

if ($records.Count -gt 0) {
  [void]$sb.Append("<h3>At a record low</h3><p>The cheapest we have ever recorded these, since tracking began:</p><ul>")
  foreach ($r in $records) {
    [void]$sb.Append('<li><strong>' + (Esc $r.label) + '</strong> at ' + (Fmt-Price $r.price $r.unit) + ', ' + (Esc $r.store) + '</li>')
  }
  [void]$sb.Append('</ul>')
}

[void]$sb.Append('<p><a href="' + $SITE + '/omaha-grocery-prices/?ref=friday">See all ' + @($doc.comparison).Count + ' items on the board &rarr;</a></p>')
[void]$sb.Append('<p><em>Prices are the lowest verified shelf price at each store, checked against the store&rsquo;s own ad or site. Sam&rsquo;s Club prices need a membership.</em></p>')

$outHtml = Join-Path $OutDir 'friday-email.html'
$outJson = Join-Path $OutDir 'friday-email.json'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($outHtml, $sb.ToString(), $utf8)

# The subject leads with the single most useful fact available, because that is what shows in the inbox.
# On a flat week a record on a spice is a weak subject line, and the subject is most of whether this
# gets opened at all. Fall through to a real staple price instead - "Eggs are $1.43 a dozen at Walmart"
# is the most useful sentence available in any week, and it is always true.
$coreRec = @($records | Where-Object { $_.core }) | Select-Object -First 1
$subject = if ($drops.Count -gt 0) {
  ('Omaha groceries: ' + $drops[0].commodity + ' down ' + [int][math]::Floor($drops[0].pct*100) + '%')
} elseif ($coreRec) {
  ('Omaha groceries: ' + $coreRec.label + ' at a record low')
} elseif ($staples.Count -gt 0) {
  ($staples[0].label + ' is ' + ((Fmt-PriceText $staples[0].price $staples[0].unit)) + ' at ' + $staples[0].store + ' this week')
} else {
  ('Omaha grocery prices, week of ' + $dateLong)
}

$meta = [ordered]@{ week = $week; subject = $subject; staples = $staples.Count; drops = $drops.Count; records = $records.Count; items = @($doc.comparison).Count; source = (Split-Path $CompareFile -Leaf) }
[IO.File]::WriteAllText($outJson, (ConvertTo-Json $meta -Depth 5), $utf8)

Write-Output ("friday email -> {0} ({1} KB)" -f $outHtml, [math]::Round((Get-Item $outHtml).Length/1KB,1))
Write-Output ("  week={0}  staples={1}  drops={2}  records={3}  source={4}" -f $week, $staples.Count, $drops.Count, $records.Count, $meta.source)
Write-Output ("  subject: {0}" -f $subject)
