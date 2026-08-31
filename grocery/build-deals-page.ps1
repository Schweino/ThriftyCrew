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

# Per-unit price DISPLAY lives in fmt-lib.ps1 so its founding bugs have a fixture that can reach them.
# Dot-sourced up here, before anything renders, because the record/verdict tooltips built further down
# format prices too - and they were a SECOND copy of the same math, which is how "$0.00/oz at Sam's Club"
# survived inside a title attribute after the visible chip had been fixed.
. (Join-Path $root 'fmt-lib.ps1')
. (Join-Path $root '..\lib\trend-keep.ps1')   # 2026-08-04: single source for which commodities get a standalone trend page
# lib\board-drops.ps1 was dot-sourced here for the masthead's biggest-drop chip. The chip went with the
# masthead on 2026-08-09; the Friday email is now the ranking's only caller, so the lib stays and this
# dot-source goes.
$doc  = Get-Content $CompareFile -Raw | ConvertFrom-Json
$cats = (Get-Content (Join-Path $root 'categories.json') -Raw | ConvertFrom-Json).categories | Sort-Object order
$week = [string]$doc.week_of

# ---- BOARD-PRICE OVERRIDES: pin the verified current per-unit for cells whose periodic source pull went
# stale (so the number stopped matching the product the "See item" link opens). Applied to EVERYDAY cells
# only - a live weekly-ad SALE always wins - and the row's cheapest/nomem winners are recomputed so the
# headline can never disagree with the chip. This is what makes a stale board price self-correct at build
# time and survive daily regeneration; audit-board-consistency re-checks it and boardmatch keeps it honest.
$ovr = @{}
$ovrFile = Join-Path $root 'board-price-overrides.json'
if (Test-Path $ovrFile) { try { foreach ($c in (Get-Content $ovrFile -Raw | ConvertFrom-Json).cells) { $k=[string]$c.id; if (-not $ovr.ContainsKey($k)) { $ovr[$k]=@{} }; $ovr[$k][[string]$c.store]=[double]$c.per_unit } } catch {} }
function Apply-Overrides($rows) {
  if (-not $rows -or $ovr.Count -eq 0) { return 0 }
  $n = 0
  foreach ($r in $rows) {
    $id=[string]$r.id; if (-not $ovr.ContainsKey($id)) { continue }
    foreach ($s in $r.stores) {
      if (([string]$s.type) -ne 'everyday') { continue }         # never clobber a live sale
      $st=[string]$s.store; if (-not $ovr[$id].ContainsKey($st)) { continue }
      $new=[double]$ovr[$id][$st]; if ($new -le 0) { continue }
      if ([math]::Abs([double]$s.per_unit - $new) -gt 0.0001) { $s.per_unit = $new; $n++ }
    }
    # recompute winners so cheapest_*/nomem_* stay consistent with the overridden per_units
    $live = @($r.stores | Where-Object { [double]$_.per_unit -gt 0 })
    if ($live.Count) {
      $w = $live | Sort-Object { [double]$_.per_unit } | Select-Object -First 1
      if ($r.PSObject.Properties.Name -contains 'cheapest_price') { $r.cheapest_price=[double]$w.per_unit; $r.cheapest_store=[string]$w.store; if ($r.PSObject.Properties.Name -contains 'cheapest_type') { $r.cheapest_type=[string]$w.type } }
      if ($r.PSObject.Properties.Name -contains 'nomem_price') {
        $nm = @($live | Where-Object { -not $_.membership }) | Sort-Object { [double]$_.per_unit } | Select-Object -First 1
        if ($nm) { $r.nomem_price=[double]$nm.per_unit; $r.nomem_store=[string]$nm.store; if ($r.PSObject.Properties.Name -contains 'nomem_type') { $r.nomem_type=[string]$nm.type } }
      }
    }
  }
  return $n
}
$ovrN = Apply-Overrides $doc.comparison

# comparison rows keyed by commodity id
$byId = @{}; foreach ($r in $doc.comparison) { $byId[[string]$r.id] = $r }

# ---- price-record badges, computed at BUILD time against the exact prices being rendered ----
# update-history.ps1 (and its records-<week>.json snapshot) only refreshes on ad-flip days, but this
# page republishes daily; recomputing here means a badge can never disagree with the chip next to it.
# Rules mirror update-history.ps1: prior cycles = history strictly BEFORE this board's ad week (a
# same-cycle daily upsert must not compete with itself), and 2+ prior weeks required before we are
# willing to call anything a record in public.
$recBadge = @{}   # id -> @{cls; label; title; rank}
$verdict  = @{}   # id -> @{cls; label; title}   Buy-or-Wait layer (only when no record badge is showing)
# stock-up set: commodities that keep (freezer/pantry) - a record price on one of these earns a "Stock up" tag
$stockup = @{}
$suFile = Join-Path $root 'stockup-items.json'
if (Test-Path $suFile) { try { $suDoc = Get-Content $suFile -Raw | ConvertFrom-Json; foreach ($p in $suDoc.items.PSObject.Properties) { $stockup[[string]$p.Name] = [string]$p.Value } } catch {} }
$histFile = Join-Path $root 'price-history.json'
if (Test-Path $histFile) {
  try {
    $histDoc = Get-Content $histFile -Raw | ConvertFrom-Json
    $histById = @{}; foreach ($h in $histDoc.commodities) { $histById[[string]$h.id] = $h }
    foreach ($r in $doc.comparison) {
      $h = $histById[[string]$r.id]; if (-not $h) { continue }
      $P = [double]$r.cheapest_price
      # outlier guard: a price >30% below the runner-up store is exactly what sanity-check.ps1 flags
      # for human review ("verify the price/size parse") - never headline one as a record until a
      # later week confirms it. Mirrors the sanity threshold; legit sale records are typically 5-25% below.
      $rank2 = @($r.stores | Sort-Object per_unit)
      if ($rank2.Count -ge 2) { $ru = [double]$rank2[1].per_unit; if ($ru -gt 0 -and (($ru - $P) / $ru) -gt 0.30) { continue } }
      $prior = @($h.history | Where-Object { try { [datetime]$_.week_of -lt [datetime]$week } catch { $false } })
      if (@($prior).Count -lt 2) { continue }
      $priorMin = $null; $priorMinStore = ''
      foreach ($e in $prior) { $ep = [double]$e.cheapest_price; if ($priorMin -eq $null -or $ep -lt $priorMin) { $priorMin = $ep; $priorMinStore = [string]$e.cheapest_store } }
      $wkN = @($prior).Count + 1
      $suNote = if ($stockup.ContainsKey([string]$r.id)) { [string]$stockup[[string]$r.id] } else { $null }
      if ($P -lt $priorMin) {
        $recBadge[[string]$r.id] = @{ cls='pg-rec-low'; label='Record low'; rank=0; su=$suNote; title=("Cheapest we have seen in " + $wkN + " weeks of tracking. Previous best " + (Fmt-PriceText $priorMin ([string]$r.unit)) + ".") }
      } elseif ($P -eq $priorMin) {
        $recBadge[[string]$r.id] = @{ cls='pg-rec-tie'; label='Ties record'; rank=1; su=$suNote; title=("Matches the lowest price in " + $wkN + " weeks of tracking.") }
      } else {
        $weeksAbove = 0; $since = $null
        foreach ($e in ($prior | Sort-Object week_of -Descending)) { if ([double]$e.cheapest_price -gt $P) { $weeksAbove++ } else { $since = $e.week_of; break } }
        if ($weeksAbove -ge 2) { $recBadge[[string]$r.id] = @{ cls='pg-rec-dip'; label=('Lowest in ' + $weeksAbove + ' wks'); rank=2; su=$suNote; title=("Cheapest since " + $since + ".") } }
        elseif ($P -le ($priorMin * 1.05)) {
          # Buy-or-Wait layer: within 5% of the tracked low = a good week to buy
          $verdict[[string]$r.id] = @{ cls='pg-verd-buy'; label='Good price'; title=("Within 5% of the lowest we have tracked (" + (Fmt-PriceText $priorMin ([string]$r.unit)) + "). A fine week to buy.") }
        }
        elseif ($P -gt ($priorMin * 1.15)) {
          # >15% above the tracked low = it usually comes back down
          $verdict[[string]$r.id] = @{ cls='pg-verd-wait'; label='Usually cheaper'; title=("Lowest we have tracked: " + (Fmt-PriceText $priorMin ([string]$r.unit)) + " at " + $priorMinStore + ". If it can wait, it usually comes back down.") }
        }
      }
    }
  } catch { $recBadge = @{} }
}

# optional: recipe-ingredient board (the 100 meal-prep recipes' ingredients, all 6 stores). Additive; renders below the weekly staples when present.
$riDoc = $null; $riCats = @()
$riFile = Join-Path $OutDir 'recipe-board.json'
if (Test-Path $riFile) { $riDoc = Get-Content $riFile -Raw | ConvertFrom-Json; $riCats = @($riDoc.comparison | ForEach-Object { [string]$_.category } | Select-Object -Unique); $ovrN += (Apply-Overrides $riDoc.comparison) }
# MERGED SECTIONS (2026-08-15, Brad's call). Recipe rows used to render as their OWN sections below the
# staples, one <h2> per distinct category string - so the page showed "Meat & Poultry" twice ("Dairy & Eggs"
# twice, and before the vocabulary was canonicalized, THREE dairy spellings at once). One category = one
# section: recipe rows are grouped here by their (canonical) category label and rendered INSIDE the matching
# weekly section, after its staple rows. $riRendered proves nothing fell through the merge.
$riByCat = @{}
$riRendered = @{}
if ($riDoc) { foreach ($r in $riDoc.comparison) { $cl = [string]$r.category; if (-not $riByCat.ContainsKey($cl)) { $riByCat[$cl] = New-Object System.Collections.ArrayList }; [void]$riByCat[$cl].Add($r) } }

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
# "Does not carry" cells: commodity x store confirmed absent (manual verification). Rendered as a muted chip
# with a "See it? Let us know!" link to the suggest-an-item form, so a genuine gap reads as intentional.
$notCarry = @{}
$ncFile = Join-Path $root 'not-carried.json'
if (Test-Path $ncFile) { $ncd = Get-Content $ncFile -Raw | ConvertFrom-Json; foreach ($e in @($ncd.cells)) { $ncid = [string]$e.id; if (-not $notCarry.ContainsKey($ncid)) { $notCarry[$ncid] = @{} }; $notCarry[$ncid][[string]$e.store] = $true } }
function IsNoneCarry([string]$id, [string]$store) { return ($notCarry.ContainsKey($id) -and $notCarry[$id].ContainsKey($store)) }
function NoneCells([string]$id) {
  if (-not $notCarry.ContainsKey($id)) { return '' }
  $out = ''
  foreach ($st in ($notCarry[$id].Keys | Sort-Object)) {
    $out += "<div class='pg-chip pg-chip-none' data-store=`"" + (HtmlEnc $st) + "`"><span class='pg-store'>" + (HtmlEnc $shortName[$st]) + "</span><span class='pg-none'>Doesn&rsquo;t carry</span><a class='pg-see pg-see-none' href='/suggest-an-item/'>See it? Let us know! &rarr;</a></div>"
  }
  return $out
}
# EVERY store gets a tile for EVERY staple commodity - a shopper must never see a commodity with a store
# silently missing. For each store in $storeOrder that has NO priced tile: show a muted card. A store confirmed
# absent (not-carried.json) reads "Doesn't carry"; a store we simply have no comparable price for reads "No
# price yet". Both carry the "See it? Let us know!" link to the suggest-an-item form so a real sighting gets
# reported (and becomes a pricing to-do). $pricedStores = the stores that already got a price tile on this row.
function MissingCells([string]$id, $pricedStores) {
  $have = @{}; foreach ($p in @($pricedStores)) { $have[[string]$p] = $true }
  $out = ''
  foreach ($st in $storeOrder) {
    if ($have.ContainsKey($st)) { continue }
    $label = if (IsNoneCarry $id $st) { 'Doesn&rsquo;t carry' } else { 'No price yet' }
    $out += "<div class='pg-chip pg-chip-none' data-store=`"" + (HtmlEnc $st) + "`"><span class='pg-store'>" + (HtmlEnc $shortName[$st]) + "</span><span class='pg-none'>" + $label + "</span><a class='pg-see pg-see-none' href='/suggest-an-item/'>See it? Let us know! &rarr;</a></div>"
  }
  return $out
}
# per-unit of a stored link, in the board's $unit, from {price,size} - used to SUPPRESS a clearly-wrong link.
. (Join-Path $PSScriptRoot 'pu-lib.ps1')
# 2026-07-26 consolidation: LinkPU now DELEGATES to pu-lib's Get-LinkPerUnit (the single per-unit
# implementation; identical params; test-pu-lib.ps1 proves it matches everywhere and resolves more).
# The former local copy - one of three drifting duplicates - is gone. Keep using LinkPU at call sites.
function LinkPU([string]$size, [string]$unit, [double]$price, [string]$name = '') { Get-LinkPerUnit -size $size -unit $unit -price $price -name $name }
# Respect the audits: suppress a link the name/form-drift audit flags as a clearly WRONG product (a
# fresh commodity linked to a frozen/canned item), which the price gate alone can miss when the per-unit
# happens to be close. Run audit-name-drift.ps1 before build so this file is current.
$formFlip = @{}
$ndFile = Join-Path $OutDir 'name-drift.json'
if (Test-Path $ndFile) { try { $nd = Get-Content $ndFile -Raw | ConvertFrom-Json; foreach ($f in $nd.flags) { if ($f.reason -eq 'form-flip') { $formFlip[([string]$f.id + '|' + [string]$f.store)] = $true } } } catch {} }
# Does the linked product's NAME describe the SAME product the board priced? Used to validate a SALE cell's
# link (where the price gate can't, because a sale price legitimately differs from the everyday snapshot). We
# require the board item's distinctive words (>3 chars, minus generic filler) to mostly appear in the link name,
# so board "Sara Lee Honey Wheat Bread" won't accept a link to "Our Family White Bread".
function NameMatch([string]$boardItem, [string]$linkName) {
  $norm = { param($s) (([string]$s).ToLower() -replace '[^a-z0-9 ]',' ' -replace '\s+',' ').Trim() }
  $filler = 'fresh|assorted|premium|natural|large|small|medium|value|pack|original|our|family|brand|select|the|and|with|each|lb|oz|count|\d+'
  $bw = @((& $norm $boardItem) -split ' ' | Where-Object { $_.Length -gt 3 -and $_ -notmatch ('^(?:' + $filler + ')$') })
  if ($bw.Count -eq 0) { return $true }   # nothing distinctive to check against -> don't block on name
  $ln = & $norm $linkName
  $hit = 0; foreach ($w in $bw) { if ($ln -match ('\b' + [regex]::Escape($w) + '\b')) { $hit++ } }
  return (($hit / $bw.Count) -ge 0.5)
}
# Commodity-identity fallback for SALE links: flyer names carry descriptive fluff ("Tree Ripened Yellow Flesh
# Peaches, Small") that a storefront product name ("Fresh Peaches") never repeats, so word-overlap NameMatch
# alone can wrongly hide a correct, price-consistent link. If the LINK name matches the commodity's own
# include patterns (and none of its excludes) it IS an instance of the same commodity; combined with a
# band-passing per-unit that's safe to show. Never used without the band (a generic include like "bread"
# matches any brand, so identity-by-include alone could bless a wrong product).
$cmIdent = @{}
try { foreach ($cdef in (Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json)) { $cmIdent[[string]$cdef.id] = @{ inc = @($cdef.include); exc = @($cdef.exclude) } } } catch {}
function CommodityIdent([string]$id, [string]$linkName) {
  if (-not $cmIdent.ContainsKey($id) -or -not $linkName) { return $false }
  $inc = $false
  foreach ($p in $cmIdent[$id].inc) { if ($p -and $linkName -imatch $p) { $inc = $true; break } }
  if (-not $inc) { return $false }
  foreach ($x in $cmIdent[$id].exc) { if ($x -and $linkName -imatch $x) { return $false } }
  return $true
}
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
# store weekly-ad landing pages (flyer-only pills link to them). Single source: ad-urls.json - the daily
# reachability warn reads the same file, so the pill and the check can never disagree about the URL.
$ADURLS = @{}
try { $adDoc = Get-Content (Join-Path $root 'ad-urls.json') -Raw | ConvertFrom-Json; foreach ($p in $adDoc.urls.PSObject.Properties) { $ADURLS[[string]$p.Name] = [string]$p.Value } } catch {}

# THE ALL-3 RULE (Brad, 2026-07-23): every tile that shows a price and a name MUST also carry a link -
# no exceptions, ever. Exact product links stay the gold standard (price-verified, the gates above), but a
# cell we cannot exactly link no longer renders as a bare name: it gets a clearly-labeled "Find at <store>"
# link to that store's own SEARCH for the item. Honest (the label says search, not item), always available
# (works even for by-weight produce that has no product page anywhere), and self-upgrading (the moment an
# exact link resolves, it replaces the search link). Enforced twice: by construction here, and by the
# post-build assertion at the bottom of this script that hard-fails the build if any priced chip somehow
# renders without an href.
$SEARCHURLS = @{
  'Walmart'     = 'https://www.walmart.com/search?q={q}'
  "Baker's"     = 'https://www.bakersplus.com/search?query={q}&searchType=default_search'
  'Hy-Vee'      = 'https://www.hy-vee.com/aisles-online/search?search={q}'
  'Aldi'        = 'https://www.aldi.us/store/aldi/s?k={q}'
  'Fareway'     = 'https://shop.fareway.com/store/fareway-meat-grocery/s?k={q}'
  "Sam's Club"  = 'https://www.samsclub.com/s/{q}'
  # Family Fare's storefront is a Freshop SPA bolted onto a WordPress marketing site. The two halves have
  # SEPARATE routers, and only the WordPress half owns clean paths: /search?search_term= and /shop/search? are
  # both "Page not found" (verified 2026-08-02 - the old /search?search_term= template 404'd for 20 live chips
  # in public/board.json). The SPA routes off the HASH-BANG fragment, and this is the exact URL the site's own
  # nav search box emits when you type into it. Two properties make it the right last resort: the fragment is
  # never sent to the server, so it cannot 404, and if the SPA ever stops parsing q the shopper still lands on
  # a working /shop instead of an error page. Re-verify by typing in the site's search box, not by HTTP status:
  # every /shop/* path returns 200 from the SPA shell, so a status code proves nothing here.
  'Family Fare' = 'https://www.shopfamilyfare.com/shop#!/?q={q}&search_option_id=product'
}
function SearchLink([string]$store, [string]$query) {
  $tpl = $SEARCHURLS[$store]
  if (-not $tpl -or -not $query) { return '' }
  $u = $tpl.Replace('{q}', [uri]::EscapeDataString($query))
  return "<a class='pg-see pg-see-search' href='" + (HtmlEnc $u) + "' target='_blank' rel='nofollow noopener' title='No exact product page for this one - opens " + (HtmlEnc $store) + "&#39;s own search for it.'>Find at store &rarr;</a>"
}

function SeeLink([string]$id, [string]$store, [string]$boardItem, [double]$boardPU, [string]$unit, [string]$cellType) {
  $url = $null
  if (($purls.ContainsKey($id)) -and ($purls[$id].ContainsKey($store)) -and (-not $formFlip.ContainsKey($id + '|' + $store))) {
    $lnk = $purls[$id][$store]
    if ($lnk.url) {
      $ok = $true
      # A "See item" link must land on the SAME product the price on the card is for. The linked product's stored
      # price is its EVERYDAY shelf price (that is what the resolver captured). How we validate depends on whether
      # THIS week the board is showing an everyday price or a SALE:
      #   EVERYDAY cell: board and the snapshot are both everyday, so they must match within ~30%; a bigger gap
      #     means a DIFFERENT pack/size/product (e.g. board = Aldi in-store $2.29 family pack, link = aldi.us $3.29
      #     per-lb tray) and we suppress -> fall back to the product name. This is the strict identity gate.
      #   SALE cell: the board shows a markdown while the snapshot is the everyday price, so for the SAME product the
      #     snapshot legitimately sits ABOVE the sale (that is what a sale IS). Hiding it here was the bug that made
      #     every on-sale item lose its link (FF chicken breast: board $1.99 sale, correct link snapshot $2.99
      #     everyday -> 50% "gap" -> wrongly hidden). So for a sale we accept a snapshot in a sane band around the
      #     sale (>= ~0.85x, up to 3x = a 67%-off sale) and rely on name-drift to catch a genuinely wrong product.
      # Missing beats wrong; the fix for a truly wrong link is still to re-resolve its URL, not to loosen this.
      if ($boardPU -gt 0) {
        $lprice = 0.0; [void][double]::TryParse((([string]$lnk.price) -replace '[^0-9.]',''), [ref]$lprice)
        $lpu = LinkPU ([string]$lnk.size) $unit $lprice ([string]$lnk.name)
        if ($cellType -eq 'sale') {
          # SALE: validate product IDENTITY by name ALWAYS (a sale price can't confirm identity, and the name check
          # must run even when the size can't be priced into a per-unit, e.g. a "20 oz" loaf on an each-based board -
          # that null-price gap is exactly how a wrong link like Our Family White for a Sara Lee board slipped through).
          # Then, when the per-unit IS computable, also require the everyday snapshot to sit in a sane band around the sale.
          $ident = (NameMatch $boardItem ([string]$lnk.name))
          # flyer-fluff rescue: word-overlap failed, but the link IS the same commodity (its own include/exclude)
          # AND its per-unit is computable and inside the sale band AND the link name is a GENERIC SUBSET of the
          # board's (every distinctive link word appears in the board item). The subset test is what stops a
          # brand swap: "Fresh Peaches" Ã¢Å â€š "Tree Ripened Yellow Flesh Peaches, Small" -> show (same commodity,
          # less flowery), but "Kroger Thick Cut Bacon" Ã¢Å â€ž "Oscar Mayer Bacon" -> still hidden (different brand,
          # even at a plausible price). Band is REQUIRED here.
          if (-not $ident -and ($null -ne $lpu) -and ($lpu -ge $boardPU * 0.85) -and ($lpu -le $boardPU * 3.0) -and (CommodityIdent $id ([string]$lnk.name)) -and (NameMatch ([string]$lnk.name) $boardItem)) { $ident = $true }
          if (-not $ident) { $ok = $false }
          elseif (($null -ne $lpu) -and ($lpu -lt $boardPU * 0.85 -or $lpu -gt $boardPU * 3.0)) {
            # PACK-BASIS AMBIGUITY on an 'each' commodity. "each" means one PACKAGE for some commodities
            # (garlic bread, a bag of buns) and one ITEM for others (a bottle out of a 24-pack). compare-deals
            # settles that per commodity; Get-LinkPerUnit cannot know, so it always DIVIDES a counted size
            # ("8 ea") by the count. Where the board priced the PACK the two sides sit on different bases and
            # the band rejects a byte-identical product: Family Fare garlic-bread, board $2.49 each vs the
            # stored link "Our Family Slices Original Garlic Texas Toast 8 Ea" $2.89 for that same 8-ct pack
            # -> lpu $0.36, a 1/8 artifact rather than a different product.
            # The rescue is deliberately narrow. The size must state a count > 1 (no ambiguity otherwise); the
            # PACK price must itself sit in the same sale band; and the names must be EQUAL after
            # normalization - the 50%-word NameMatch above is far too weak to be the only thing between a
            # shopper and a wrong product page ("Kroger Cheese Texas Toast 8 Ea" passes NameMatch against the
            # Our Family board item). Missing still beats wrong.
            $packOk = $false
            if ($unit -eq 'each') {
              $pkm = [regex]::Match(([string]$lnk.size).ToLower(), '^\s*([0-9]+)\s*(?:ea|each|ct|count|pk|pack)\s*$')
              if ($pkm.Success -and ([double]$pkm.Groups[1].Value -gt 1) -and ($lprice -ge $boardPU * 0.85) -and ($lprice -le $boardPU * 3.0)) {
                $nbNorm = (([string]$boardItem).ToLower() -replace '[^a-z0-9]',' ' -replace '\s+',' ').Trim()
                $nlNorm = (([string]$lnk.name).ToLower() -replace '[^a-z0-9]',' ' -replace '\s+',' ').Trim()
                $packOk = ($nbNorm -eq $nlNorm) -and $nbNorm
              }
            }
            if (-not $packOk) { $ok = $false }
          }
        }
        elseif ($null -ne $lpu -and ([math]::Abs($lpu - $boardPU) / $boardPU -gt 0.30)) {
          # >30% off the board on an EVERYDAY cell normally means a DIFFERENT product -> hide. The one exception is
          # AD-ROLLOFF: a sale just ended and the board reverted UP to everyday, but the stored snapshot still holds
          # the lower SALE price of the SAME product. That shape is snapshot CHEAPER than the board (within a floor)
          # with a matching NAME -> keep the link. A snapshot PRICIER than the board is a wrong pricier SKU (the Aldi
          # tray) -> stay hidden. Purely additive: only rescues a rolled-off link, never shows a pricier mismatch.
          if (-not (($lpu -lt $boardPU) -and ($lpu -ge $boardPU * 0.3) -and (NameMatch $boardItem ([string]$lnk.name)))) { $ok = $false }
        }
      }
      if ($ok) { $url = [string]$lnk.url }
    }
  }
  if ($url) { return "<a class='pg-see' href='" + (HtmlEnc $url) + "' target='_blank' rel='nofollow noopener'>See item &rarr;</a>" }
  $nm = CleanItemName $boardItem
  # A SALE cell with no link is usually a flyer-only item: the weekly ad IS the source and there is no product
  # page to open. Say so, AND hand the shopper the source: the pill links to the store's current weekly ad
  # (evergreen URL - it always opens this week's flyer, so it cannot go stale mid-week). It opens the AD, not
  # the item - flyer viewers have no reliable per-item anchors - so the copy promises only "the ad".
  # (Everyday no-link cells stay plain - those ARE gaps we intend to close.)
  if ($nm -and $cellType -eq 'sale') {
    $adU = $ADURLS[$store]
    $pill = if ($adU) {
      "<a class='pg-adonly' href='" + (HtmlEnc $adU) + "' target='_blank' rel='nofollow noopener' title='Flyer-only price from this week&#39;s " + (HtmlEnc $store) + " ad. Opens the ad; find the item inside.'>weekly ad &#8599;</a>"
    } else { (SearchLink $store $boardItem) }   # no ad URL for this store -> the all-3 rule still holds via search
    # pill is a SIBLING of the name, not inside it: the name clamps at 2 lines, and a clamped container
    # would clip the pill exactly when the name is long.
    return "<span class='pg-itemname' title='" + $nm + " - priced from the weekly ad'>" + $nm + "</span>" + $pill
  }
  # ALL-3 RULE: an everyday cell with no exact link renders the name PLUS the store-search link, never a
  # bare name. And a priced cell with no name at all still gets a search link on the commodity so the tile
  # can never show a price with nothing to click.
  $q = if ($boardItem) { [string]$boardItem } else { ($id -replace '-', ' ') }
  if ($nm) { return "<span class='pg-itemname' title='" + $nm + "'>" + $nm + "</span>" + (SearchLink $store $q) }
  return (SearchLink $store $q)
}

# canonical store order - drives the per-row grid, the store-status strip and the masthead counts
$storeOrder = @('Hy-Vee','Aldi','Family Fare','Fareway',"Baker's","Sam's Club",'Walmart')

# short store display names + stable column color accents
$shortName = @{ 'Hy-Vee'='Hy-Vee'; 'Aldi'='Aldi'; 'Family Fare'='Family Fare'; 'Fareway'='Fareway'; "Baker's"="Baker's"; "Sam's Club"="Sam's Club"; 'Walmart'='Walmart' }

# NOTE: must escape single quotes too - several attributes (title='...', href='...') are single-quoted,
# and store-brand names routinely contain apostrophes (Member's Mark, Driscoll's, Land O'Lakes, Baker's).
function HtmlEnc([string]$s) { if ($null -eq $s) { return '' }; return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;' -replace "'",'&#39;') }

# Per-unit price display now lives in fmt-lib.ps1 (Fmt-Price + UnitLabel) so its founding bugs - the
# "356&cent;/oz" no-rollover case and the "$0.00 each" sub-cent case - have a fixture that can actually
# reach them. Behaviour at the call sites is unchanged; only the definition moved.
. (Join-Path $root 'fmt-lib.ps1')
# The design system (tokens, motion vocabulary, z-ladder, store accents, self-checks) is shared with the
# meal-prep builders so the two surfaces cannot drift into two products.
. (Join-Path $root '..\lib\design-tokens.ps1')
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
  # ONLY AN AD-BACKED SALE MAY WEAR AN AD-CYCLE DATE.
  # The window below belongs to the store's weekly AD. A sale cell that did not come from that ad has no claim
  # on it. This function used to badge every sale chip regardless of source, so a one-off "Aisles Online
  # markdown" snapshot - undated, unverifiable, and two days stale - was published as
  # "Hy-Vee $6.99/lb - Sale thru Jul 19". The store's real price that day was $11.99/lb. The invented date is
  # what made the wrong number look trustworthy. No date beats a date we made up.
  if (([string]$s.source_ad) -match '(?i)markdown|clearance|snapshot') { return '' }
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
  'Fareway'     = @('fareway\fareway-deals-*.json','regular\fareway-regular-*.json')
}
function NewestUpd($globs) { $m=$null; foreach ($g in $globs) { $f = Get-ChildItem (Join-Path $OutDir $g) -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($f -and (($null -eq $m) -or ($f.LastWriteTime -gt $m))) { $m = $f.LastWriteTime } }; return $m }

# ---- build the category sections ----
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append("<div class='pg-wrap'>")
[void]$sb.Append("<header class='pg-head'>")
if (-not $Embed) { [void]$sb.Append("<h1>Omaha's Cheapest Groceries This Week</h1>") }   # Embed: Ghost post title is the H1
[void]$sb.Append("<p class='pg-sub'>The cheapest place to buy every grocery staple in Omaha this week. Seven stores, checked every morning, ranked cheapest first.</p>")
# The masthead band was injected here (a <!--PG-MASTHEAD--> placeholder filled at the end of the build).
# Removed 2026-08-09; see the note where it used to be built.
# Retailers do not share one ad boundary. The promotion coordinator refreshes each store at its own
# start/end boundary, while the daily pass remains the independent freshness backstop.
[void]$sb.Append("<p class='pg-cycle'>Sale prices update as each retailer's ad starts or ends. This board is also re-checked every morning.</p>")
# THE TRUST COPY, collapsed. It matters and it stays word for word, but as three stacked paragraphs it
# pushed the first actual price below two viewports on a phone. One <details> keeps every claim on the page
# and in the HTML for search, and gives the board back a screen and a half.
# (The trust line is Brad's voice, approved 2026-07-17. Do not edit the wording without Brad.)
[void]$sb.Append("<details class='pg-how'><summary>How this board works</summary>")
[void]$sb.Append("<p class='pg-note'>Lowest verified price at each store, sale or everyday, checked against the store's own ad or site. Sam's Club prices need a membership.</p>")
[void]$sb.Append("<p class='pg-trust'>I'm Brad. I live here in Omaha, and I check these prices every morning before most people are awake. No store pays to be on this board, there are no affiliate links, and no one can buy the word 'cheapest.' If a store wins, it's because their shelf price won.</p>")
# The recipe-ingredient honesty note lived above their own (now-removed) sections; merged rows carry a
# per-row "shelf price" marker and the dated explanation moves here so nothing reads fresher than it is.
if ($riDoc) {
  $riDate = ''
  try { $riBase = Join-Path $OutDir 'recipe-board-everyday.json'; $riStamp = if (Test-Path $riBase) { $riBase } else { $riFile }; $riDate = ([datetime](Get-Item $riStamp).LastWriteTime).ToString('MMM d, yyyy') } catch {}
  [void]$sb.Append("<p class='pg-note'>Rows marked <strong>shelf price</strong> are recipe ingredients at their regular shelf price (checked " + (HtmlEnc $riDate) + ", re-checked monthly). When one goes on sale in a weekly ad, the sale price shows automatically with its end date.</p>")
}
[void]$sb.Append("</details>")
# Both per-row features (the price-history chart and the price alert) are hidden until a row is opened,
# so nothing on a first read reveals they exist. One sentence, above the first price.
[void]$sb.Append("<p class='pg-teach'>Tap any item for its full price history, or to get an email the week it hits a record low.</p>")
[void]$sb.Append("<p class='pg-suggest'><a href='/suggest-an-item/'>Suggest an item for us to start tracking! &rarr;</a></p></header>")
# THE ASK moves out of the header to between the first and second category sections. 1,182 visitors in 30
# days reached this page and converted once; ask-after-value beats ask-before-value, and the header was
# asking before the shopper had seen a single price. Emitted as a token and placed during the section loop.
    # 2026-08-04: was an <a> to #/portal/signup/free. The offer and the placement were right and are
# unchanged; only the mechanism moved inline, so the reader types an address instead of being handed
# a modal. data-members-form / data-members-email / data-members-error mirror the theme's own footer
# form exactly, which is what Ghost's Portal script binds to.
$captureHtml = "<div class='pg-capture'>" +
  "<span class='pg-capture-eb'>Free weekly email</span>" +
  "<p class='pg-capture-txt'><strong>Get this board every Friday, free.</strong> The updated prices and biggest drops, in your inbox before you shop the weekend.</p>" +
  "<form data-members-form><label class='pg-sr' for='pg-cap-email'>Your email address</label>" +
  "<input id='pg-cap-email' name='email' type='email' placeholder='you@email.com' required data-members-email>" +
  "<button type='submit'>Email me the board</button>" +
  "<p data-members-error></p></form>" +
  "<p class='pg-capture-fine'>One email a week. Unsubscribe in one click.</p>" +
  "<p class='pg-capture-done'>Check your inbox. Click the link in the email and you are on the list.</p>" +
  "</div>"

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

# The cheapest-store scoreboard and the price-records band both used to render here (2026-08-09: removed at
# Brad's request). The per-row gold record flags still mark every record low/tie/dip in the list itself, and
# the masthead chip still headlines one of them, so nothing the badge pass computes is orphaned.
# ---- trip planner home: ALWAYS visible up top so shoppers know it exists ----
[void]$sb.Append("<div class='pg-tripbox' id='pg-tripbox'><h3>Plan your shopping trip</h3>")
[void]$sb.Append("<p class='pg-tripbox-sub' id='pg-tripbox-sub'>Tick the box next to each item you want to buy, then come back here. Tell us how many stores you are willing to visit and we will split your list for the cheapest trip. <button type='button' class='pg-demo' id='pg-demo'>Try it: the family staples basket</button></p>")
[void]$sb.Append("<div id='pg-tripbox-body' hidden><p class='pg-tripbox-n'><b id='pg-tripbox-count'>0 items</b> selected. How many stores are you willing to visit?</p><div class='pg-plan-kbtns' id='pg-plan-kbtns'></div><div class='pg-plan-out' id='pg-plan-out'></div><p class='pg-plan-note'>Based on this week's verified per-unit prices. Register totals vary by package size.</p></div></div>")
# hide-Sam's toggle: recomputes the cheapest flags for shoppers without a membership
[void]$sb.Append("<label class='pg-toggle'><input type='checkbox' id='pg-hidesams'><span>Hide Sam's Club</span><span class='pg-toggle-note'>membership required: toggle to see the best price without one</span></label>")
# show-all toggle: opens every row's full 7-store grid at once (default is the compact one-line view)
[void]$sb.Append("<label class='pg-toggle'><input type='checkbox' id='pg-expandall'><span>Show all prices</span><span class='pg-toggle-note'>expand every item to compare all stores at once</span></label>")

# ---- sticky control bar: search + consolidated filter pills ----
# The two boards' category taxonomies overlap ("Fruit"/"Vegetables" vs "Produce", "Dairy & Eggs" vs
# "Cheese & Dairy") - shoppers should never see that seam. Pills are GROUPS mapping to one or more
# data-cat keys (data-cats attr, pipe-separated); the catch-all Pantry group must stay LAST.
$groupDefs = @(
  @{ label = 'Meat &amp; Poultry';      rx = 'Meat|Poultry|Seafood' },
  @{ label = 'Dairy &amp; Eggs';        rx = 'Dairy|Cheese|Egg' },
  @{ label = 'Produce';                 rx = 'Fruit|Vegetable|Produce' },
  @{ label = 'Bread &amp; Bakery';      rx = 'Bakery|Bread' },
  @{ label = 'Canned &amp; Soup';       rx = 'Canned|Soup|Beans' },
  @{ label = 'Sauces &amp; Condiments'; rx = 'Condiment|Sauce' },
  @{ label = 'Baking &amp; Spices';     rx = 'Baking|Spice' },
  @{ label = 'Pasta, Rice &amp; Grains';rx = 'Grain|Pasta|Rice|Noodle' },
  @{ label = 'Coffee, Oils &amp; Spreads'; rx = 'Oil|Coffee|Spread' },
  @{ label = 'Snacks &amp; Drinks';     rx = 'Snack|Candy|Beverage|Drink' },
  @{ label = 'Frozen';                  rx = 'Frozen' },
  @{ label = 'Household';               rx = 'Household|Cleaning|Paper' },
  @{ label = 'Personal Care';           rx = 'Personal|Health|Beauty' },
  @{ label = 'Baby &amp; Pet';          rx = 'Baby|Pet|Infant' },
  @{ label = 'More';                    rx = '.' }   # catch-all - only renders if a category matched nothing above (kept for safety)
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

# Progressive disclosure (2026-07-13): at 300+ items every row collapses to a one-line "cheapest here"
# summary; the full 7-store grid opens on tap. This builds the summary chip (cheapest store + price) that
# rides in the row head. JS (pgSummaries) refreshes it live when Hide-Sam's changes the cheapest.
# LEDGER ROW. Name, store dot-chip, dotted leader, price on a fixed right edge. The leader is one empty
# span, not a border trick on the name, so a long item name truncates and the price never moves. The store
# dot is the registry hue (stores.json), which is what makes "who keeps winning" scannable at speed.
# The sale tick rides here too: the On-sale filter existed but nothing on an unfiltered row said which
# ones would survive it.
$storeAccent = Get-TcStoreAccents
$catFlagN = @{}
$flagTotal = 0
# ONE CHECKBOX SPEC (elite-layer conflict ruling): 24px, a REAL <input>, so the label, the keyboard, screen
# readers and the existing .pg-pick selector all keep working, and a thumb can hit it.
#
# NODE BUDGET IS THE DESIGN CONSTRAINT ON THIS PAGE, and it beats the prettier implementation. The recipe
# pages get the SVG stroke-draw check (two nodes, on one page); 572 board rows would pay 1,144 nodes for
# the same 140ms of animation, and this page is the one that froze a renderer. So on the board the check,
# the chevron and the store dot are all pure CSS on elements that already exist:
#   check   -> input[type=checkbox]{appearance:none} + :checked::after       (saves 3 nodes/row)
#   chevron -> .pg-rh-top::after                                             (saves 1 node/row)
#   dot     -> .pg-sum-s::before, hue passed as a custom property            (saves 1 node/row)
#   leader  -> a repeating background on .pg-rh-top, masked by the name and
#              price backgrounds, instead of a spacer span                   (saves 1 node/row)
#              (DESKTOP ONLY since 2026-08-31: the phone row head is two lines so the name can wrap, and a
#               single-baseline background cannot follow it. See .pg-name and @media(min-width:700px).)
# That is 6 nodes x 572 rows = 3,432 nodes, which is the difference between missing and clearing the
# under-8,000 target. The look is identical; only the animation on the check is simpler.
function PickBox {
  return "<label class='pg-pickl' title='Add to my shopping list'><input type='checkbox' class='pg-pick' aria-label='Add to my shopping list'></label>"
}
function SummaryHtml($best, [string]$unit) {
  if (-not $best) { return '' }
  $tag = if ([string]$best.type -eq 'sale') { " <span class='pg-tag pg-tag-sale'>sale</span>" } else { '' }
  $hue = if ($storeAccent.Contains([string]$best.store)) { [string]$storeAccent[[string]$best.store] } else { '#5a6862' }
  # .pg-sum-s is a SIBLING of .pg-sum, not a child: flex order only reorders items inside the same flex
  # container, and the store has to become its own line of .pg-rh-top so the name gets the row's full width.
  # Node count is unchanged - the same two spans, one level up. pgSummaries() below writes them separately.
  return "<span class='pg-sum'><span class='pg-sum-p'>" + (Fmt-Price ([double]$best.per_unit) $unit) + "</span>" + $tag + "</span><span class='pg-sum-s' style='--sd:" + $hue + "'>" + (HtmlEnc $shortName[[string]$best.store]) + "</span>"
}

# (The "Deals right now" strip was removed 2026-07-13 per Brad. Record-low / sale badges still ride inline on
# each item's row, and the On-sale filter pill surfaces the sales - so nothing is lost by dropping the strip.)

# Registered staples (commodities.json). Every one owes shoppers all 7 stores WHEREVER it renders - the
# store-coverage gate holds the whole registry to that rule. $stapleRendered records which of them actually got
# a staple row below; a registered staple that has NO staple row (priced only as a recipe ingredient) must
# instead pick up the 7-store guarantee on its recipe row (see the recipe section) so build and audit agree.
$stapleIdSet = @{}
try { foreach ($sc in (Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json)) { $stapleIdSet[[string]$sc.id] = $true } } catch {}
$stapleRendered = @{}
$totalCommodities = 0; $totalPrices = 0
# id -> rendered store-chip html. Written to public/board.json and injected client-side instead of shipped in
# the post. The chips are .pg-stores{display:none} until a row is opened, so they were ~1.1 MB of HIDDEN markup
# inside the post - and that pushed the Ghost upsert past its processing timeout (503 = the board could not
# publish AT ALL, which is what kept the Fareway price-mode fix off the live site). The row head keeps the
# server-rendered answer (SummaryHtml = cheapest store + price), so first paint and SEO are unchanged, and the
# feed carries the SAME rendered html so there is no client re-render to drift and the audits reuse their regexes.
$boardChips = [ordered]@{}
# ---- WHY IS THIS THE CROWN? (2026-08-22, PLAN-product-identity step 1) ----------------------------
# Until now the board could not answer it anywhere. compare-deals records, per product, the include
# pattern that claimed it, how many excludes were tested, and which other commodities also wanted it;
# this joins that to each rendered chip.
#
# A SHORT TOKEN, NOT THE PATTERN TEXT (section 10.19). public\board.json is a 2.5 MB asset cached
# per-colo and fetched by every reader; "matched by \bblack\s+beans?\b" on ~3,000 chips is hundreds of
# KB of regex shipped to people who will never look at it. So the chip carries
#     data-mb="<include index>/<excludes tested>[+<contested count>]"
# and the text stays in graph\identity\, where -Explain and the audits already read it.
#
# FAIL SOFT, AND SILENTLY BY DESIGN. The identity table is regenerated every morning and its parity
# gate is still ADVISORY (section 10.17). A page build must never fail, or even change, because a
# marker could not be resolved - so an unresolved chip simply carries no attribute. The gate, not this,
# is what reports a table that disagrees with the board.
$idIndexByNs = @{}
try {
  . (Join-Path $root 'identity-lib.ps1')
  . (Join-Path $root 'match-lib.ps1')     # Get-MatchTexts only - no matcher is built here, so no Add-Type
  $idPageHash = Get-IdentityRulesHash -GroceryRoot $root
  foreach ($ns in @('staple', 'recipe')) {
    $ixNs = Read-IdentityIndexByName -GroceryRoot $root -Namespace $ns -RulesHash $idPageHash
    if ($null -ne $ixNs) { $idIndexByNs[$ns] = $ixNs.rows }
  }
} catch { $idIndexByNs = @{} }
function MatchToken([string]$ns, [string]$store, [string]$item) {
  if (-not $idIndexByNs.ContainsKey($ns) -or -not $item) { return '' }
  $r = $idIndexByNs[$ns][($store + '|' + (Get-MatchTexts $item)[1])]
  if ($null -eq $r) { return '' }
  $t = [string]$r.include_hit_ix + '/' + [string]$r.excludes_tested
  $nc = @($r.candidates).Count
  if ($nc -gt 0) { $t += '+' + $nc }
  return " data-mb='" + $t + "'"
}
$secN = 0
foreach ($c in $cats) {
  $secN++
  # ask-after-value: the email panel lands after the shopper has scrolled one full category of real prices
  if ($secN -eq 2) { [void]$sb.Append($captureHtml); $captureHtml = '' }
  [void]$sb.Append("<section class='pg-cat' data-cat='" + $c.key + "'><h2 class='pg-cath'>" + (HtmlEnc $c.label) + "</h2>")
  foreach ($cid in $c.commodities) {
    $r = $byId[[string]$cid]
    if (-not $r) { continue }
    $ranked = @($r.stores | Where-Object { -not (IsNoneCarry ([string]$r.id) ([string]$_.store)) } | Sort-Object per_unit)
    if ($ranked.Count -eq 0) { continue }
    # 7-STORE GUARANTEE: every priced store MUST be a known store in $storeOrder, else MissingCells would ALSO
    # emit a "No price yet" card for it (a duplicate/wrong-name store on the row). Fail the build before publish.
    foreach ($chk in $ranked) { if ($storeOrder -notcontains [string]$chk.store) { throw ("build-deals-page: commodity '" + $r.id + "' is priced at unknown store '" + [string]$chk.store + "' (not in storeOrder) - would break the all-stores-shown guarantee. Fix the store name in the data.") } }
    $totalCommodities++
    $stapleRendered[[string]$r.id] = $true
    $unit = [string]$r.unit
    [void]$sb.Append("<article class='pg-row' data-cat='" + $c.key + "' data-id='" + [string]$r.id + "'>")
    $rb = $recBadge[[string]$r.id]
    $rbHtml = if ($rb) { "<span class='pg-rec " + $rb.cls + "' title=`"" + (HtmlEnc $rb.title) + "`">" + $rb.label + "</span>" } else { "" }
    # stock-up tag rides a record/tie/dip badge on a commodity that keeps (freezer/pantry)
    if ($rb -and $rb.su) { $rbHtml += "<span class='pg-rec pg-stockup' title=`"" + (HtmlEnc ("At or near its tracked low and it keeps: " + $rb.su + ". Worth buying extra.")) + "`">Stock up</span>" }
    # Buy-or-Wait verdict shows only when no record badge is on the row
    $vd = $verdict[[string]$r.id]
    if (-not $rb -and $vd) { $rbHtml += "<span class='pg-rec " + $vd.cls + "' title=`"" + (HtmlEnc $vd.title) + "`">" + $vd.label + "</span>" }
    $sumHtml = SummaryHtml $ranked[0] $unit
    # RECORD FLAG in the collapsed row. The full badge already lives in the opened row; this is the small
    # gold marker that makes a record findable while scrolling. Capped per category so a week where
    # everything dips does not turn the whole board gold and stop meaning anything.
    $flagHtml = ''
    if ($rb -and $rb.cls -eq 'pg-rec-low') {
      if (-not $catFlagN.ContainsKey($c.key)) { $catFlagN[$c.key] = 0 }
      if ($catFlagN[$c.key] -lt 4) { $catFlagN[$c.key]++; $flagHtml = "<span class='pg-flag' title='Cheapest we have tracked'>record</span>"; $flagTotal++ }
    }
    [void]$sb.Append("<div class='pg-rowhead'><div class='pg-rh-top'>" + (PickBox) + "<span class='pg-name'>" + (HtmlEnc $r.commodity) + "</span>" + $flagHtml + $sumHtml + "</div><div class='pg-rh-bot'><span class='pg-unit'>" + (UnitLabel $unit) + "</span>" + $rbHtml + "</div></div>")
    $cb = New-Object System.Text.StringBuilder
    $i = 0
    foreach ($s in $ranked) {
      $totalPrices++
      $isBest = ($i -eq 0)
      $cls = 'pg-chip'; if ($isBest) { $cls += ' is-best' }
      $notes = @()
      if ($s.membership) { $notes += $(if ([string]$s.member_label) { [string]$s.member_label } else { 'membership' }) }
      if ($s.bulk) { $notes += 'bulk' }
      $typeTag = if ([string]$s.type -eq 'sale') { "<span class='pg-tag pg-tag-sale'>sale</span>" } else { "<span class='pg-tag'>everyday</span>" }
      [void]$cb.Append("<div class='" + $cls + "' data-store=`"" + (HtmlEnc ([string]$s.store)) + "`" data-pu='" + ('{0:F4}' -f [double]$s.per_unit) + "'" + (MatchToken 'staple' ([string]$s.store) ([string]$s.item)) + ">")
      if ($isBest) { [void]$cb.Append("<span class='pg-best'>Cheapest</span>") }
      [void]$cb.Append("<span class='pg-store'>" + (HtmlEnc $shortName[[string]$s.store]) + "</span>")
      [void]$cb.Append("<span class='pg-price'>" + (Fmt-Price ([double]$s.per_unit) $unit) + "</span>")
      [void]$cb.Append("<span class='pg-meta'>" + $typeTag + ($(if ($notes.Count) { " <span class='pg-note2'>" + (HtmlEnc ($notes -join ', ')) + "</span>" } else { '' })) + "</span>")
      [void]$cb.Append((SaleBadge $s ([string]$s.store)))
      [void]$cb.Append((SeeLink ([string]$r.id) ([string]$s.store) ([string]$s.item) ([double]$s.per_unit) $unit ([string]$s.type)))
      [void]$cb.Append("</div>")
      $i++
    }
    [void]$cb.Append((MissingCells ([string]$r.id) (@($ranked | ForEach-Object { [string]$_.store }))))
    # KEY BY ROW, NOT BY ID. 54 ids (milk, butter, pork-tenderloin...) render TWICE - once as a weekly staple
    # and once as a recipe ingredient - and the two rows legitimately differ (butter is $/lb weekly vs $/oz in
    # the recipe board). Keying the chip feed by id alone let the recipe row overwrite the staple's chips, which
    # would have silently shown recipe-unit prices on the staple row. The staple row owns the bare id.
    $boardChips[[string]$r.id] = $cb.ToString()
    [void]$sb.Append("<div class='pg-stores' data-lazy='1' data-ck='" + (HtmlEnc ([string]$r.id)) + "'></div></article>")
  }
  # ---- recipe-ingredient rows for THIS category, merged into the same section (2026-08-15) ----
  # One category = one section. These rows keep their own chip-feed key (::r - the same id can exist as a
  # weekly staple with a DIFFERENT unit) and carry a per-row "shelf price" marker because the old separate
  # section's honesty note no longer sits above them; the dated explanation lives in "How this board works".
  foreach ($r in @($(if ($riByCat.ContainsKey([string]$c.label)) { $riByCat[[string]$c.label] } else { @() }))) {
    $ranked = @($r.stores | Where-Object { -not (IsNoneCarry ([string]$r.id) ([string]$_.store)) } | Sort-Object per_unit)
    if ($ranked.Count -eq 0) { $riRendered[[string]$r.id] = $true; continue }
    $totalCommodities++
    $riRendered[[string]$r.id] = $true
    $unit = [string]$r.unit
    [void]$sb.Append("<article class='pg-row' data-cat='" + $c.key + "' data-id='" + [string]$r.id + "'>")
    $sumHtml = SummaryHtml $ranked[0] $unit
    $riMark = "<span class='pg-rec pg-ri' title='Regular shelf price for a recipe ingredient, re-checked monthly; a weekly-ad sale overrides it automatically.'>shelf price</span>"
    [void]$sb.Append("<div class='pg-rowhead'><div class='pg-rh-top'>" + (PickBox) + "<span class='pg-name'>" + (HtmlEnc $r.commodity) + "</span>" + $sumHtml + "</div><div class='pg-rh-bot'><span class='pg-unit'>" + (UnitLabel $unit) + "</span>" + $riMark + "</div></div>")
    $cb = New-Object System.Text.StringBuilder
    $i = 0
    foreach ($s in $ranked) {
      $totalPrices++
      $isBest = ($i -eq 0)
      $cls = 'pg-chip'; if ($isBest) { $cls += ' is-best' }
      $notes = @()
      if ([string]$s.store -eq "Sam's Club") { $notes += 'membership' }
      if ($s.bulk) { $notes += 'bulk' }
      [void]$cb.Append("<div class='" + $cls + "' data-store=`"" + (HtmlEnc ([string]$s.store)) + "`" data-pu='" + ('{0:F4}' -f [double]$s.per_unit) + "'" + (MatchToken 'recipe' ([string]$s.store) ([string]$s.item)) + ">")
      if ($isBest) { [void]$cb.Append("<span class='pg-best'>Cheapest</span>") }
      [void]$cb.Append("<span class='pg-store'>" + (HtmlEnc $shortName[[string]$s.store]) + "</span>")
      [void]$cb.Append("<span class='pg-price'>" + (Fmt-Price ([double]$s.per_unit) $unit) + "</span>")
      $riTag = if ([string]$s.type -eq 'sale') { "<span class='pg-tag pg-tag-sale'>sale</span>" } else { "<span class='pg-tag'>everyday</span>" }
      [void]$cb.Append("<span class='pg-meta'>" + $riTag + ($(if ($notes.Count) { " <span class='pg-note2'>" + (HtmlEnc ($notes -join ', ')) + "</span>" } else { '' })) + "</span>")
      [void]$cb.Append((SaleBadge $s ([string]$s.store)))
      [void]$cb.Append((SeeLink ([string]$r.id) ([string]$s.store) ([string]$s.item) ([double]$s.per_unit) $unit ([string]$s.type)))
      [void]$cb.Append("</div>")
      $i++
    }
    if ($stapleIdSet.ContainsKey([string]$r.id) -and -not $stapleRendered.ContainsKey([string]$r.id)) {
      [void]$cb.Append((MissingCells ([string]$r.id) (@($ranked | ForEach-Object { [string]$_.store }))))
    } else {
      [void]$cb.Append((NoneCells ([string]$r.id)))
    }
    $boardChips[([string]$r.id + '::r')] = $cb.ToString()
    [void]$sb.Append("<div class='pg-stores' data-lazy='1' data-ck='" + (HtmlEnc ([string]$r.id)) + "::r'></div></article>")
  }
  [void]$sb.Append("</section>")
}
# NOTHING FALLS THROUGH THE MERGE. A recipe row whose category is not one of categories.json's sections has
# nowhere to render; silently dropping it would hide real prices, and rendering it as its own section is the
# duplicate-header bug this merge exists to kill. Brad's rule (2026-08-15): duplicate categories must NEVER
# happen; a genuinely new category is added to categories.json FIRST, which makes it a section here.
if ($riDoc) {
  $unplaced = @($riDoc.comparison | Where-Object { -not $riRendered.ContainsKey([string]$_.id) })
  if ($unplaced.Count) {
    throw ("build-deals-page: " + $unplaced.Count + " recipe row(s) have a category outside categories.json and cannot be placed: " + ((@($unplaced | ForEach-Object { [string]$_.id + ' [' + [string]$_.category + ']' }) | Select-Object -First 6) -join ', ') + ". Fix the rows in out\recipe-board-everyday.json (or register the genuinely new category in categories.json), then re-run recipe-overlay.ps1.")
  }
}

# The standalone recipe-ingredient sections were REMOVED 2026-08-15 (Brad: duplicate categories must NEVER
# happen). Recipe rows now render inside their weekly category section (see the merge in the section loop
# above), and the honesty note about everyday floors lives in "How this board works".

# membership CTA: this page is the site's best proof asset - close the loop from free prices to the $1 offer.
[void]$sb.Append("<div class='pg-cta'><h3>The prices are free. The dinners are about a dollar a month.</h3>")
[void]$sb.Append("<p>This board tells you where the cheap groceries are. The membership turns them into dinners: <span class='tc-rc'>500+</span> meal-prep recipes costed to the plate, plus the 52-week money program. It pays for itself in one grocery run.</p>")
[void]$sb.Append("<p class='pg-cta-row'><a class='pg-cta-btn' href='#/portal/signup'>Join for $1 a month &rarr;</a> <a class='pg-cta-alt' href='/meal-prep-recipes/'>or browse a few recipes free</a></p>")
[void]$sb.Append("<p class='pg-cta-fine'>Not a trial, not an intro rate. $1 a month is the whole price, and it gets everything.</p></div>")
# transparency strip lives down here with the fine print, not above the prices
[void]$sb.Append($statusHtml)
[void]$sb.Append("<footer class='pg-foot'><p>" + $totalCommodities + " staples compared across Omaha stores &middot; " + $totalPrices + " live prices &middot; week of " + (HtmlEnc $week) + ".</p>")
[void]$sb.Append("<p class='pg-disc'>Prices change often and can vary by store; we verify against each store's own ad or site, never a delivery app. This is a free weekly guide, not a guarantee of in-store price.</p></footer>")
# ---- trip planner: floating selection bar + store-split panel (fixed position; populated by JS) ----
# bottom floating bar stays for redundancy; its button scrolls back up to the always-visible planner box
[void]$sb.Append("<div class='pg-tripbar tc-bar' id='pg-tripbar' hidden><span class='pg-trip-txt'><span class='pg-trip-n' id='pg-trip-n'>0 items</span><span class='pg-trip-sub' id='pg-trip-sub'></span></span><button class='pg-trip-plan' id='pg-trip-plan'>Plan my trip &uarr;</button><button class='pg-trip-clear' id='pg-trip-clear'>Clear</button></div>")
[void]$sb.Append("</div>")

# =====================================================================================================
# THE MASTHEAD - REMOVED 2026-08-09 (Brad's call), and with it the whole navy band
# =====================================================================================================
# What used to be built here: the freshness line, the tally (items / prices verified / weeks tracked), the
# wrong-store stat ("a median N% more at a typical store"), and the biggest-drop chip. All gone.
#
# The three counts are NOT lost - the page footer still states commodities, live prices and the week. The
# drop ranking is NOT orphaned either: lib\board-drops.ps1 is the shared source and the Friday email is its
# other caller, so it stays put with one caller instead of two.
#
# Anything re-adding a top-of-page band should read design\design-elite-layer-2026-07-31.md, which still
# specs this masthead. That doc is a shipped-then-cut record, not an unbuilt requirement.
$body = $sb.ToString()
# a category-2 page (or a board with one section) never reached the capture insert point; place it before
# the membership CTA rather than dropping it, so the ask can never silently disappear from the page
if ($captureHtml) { $body = $body.Replace("<div class='pg-cta'>", $captureHtml + "<div class='pg-cta'>") }

$css = @'
<style>
/* TOOL, not article: hide the blog chrome (byline/read-time/excerpt) and the financial-advice disclaimer
   on this page only (this CSS ships inside the page embed). A grocery list is not financial advice. */
.gh-article-header .gh-article-meta,.gh-article-header .gh-article-author,.gh-article-header [class*="byline"],.gh-article-excerpt,.mts-disclaimer{display:none !important}
/* brand harmony: navy ink + gold accents to match the site; green stays ONLY where it means savings */
/* min-width:0 AND width:100% are BOTH LOAD-BEARING: pg-wrap sits in the theme's CSS grid column, whose
   items default to min-width:auto, so any non-wrapping strip's intrinsic width (pills ~526px, the 16-chip
   deals row ~2300px) inflates the whole board past the phone viewport and everything clips at the right
   edge. min-width:0 lets the item shrink; width:100% makes its width DEFINITE (= the column, not content)
   so the grid never grows to min-content. width:100% is the cross-browser clamp - contain:inline-size on
   the inner strips only helps on Safari 16.4+; older Safari ignores it and needs the definite width here. */
.pg-wrap{min-width:0;width:100%;max-width:100%;--ink:#16263F;--green:#10794e;--green-d:#0c5c3b;--green-t:#e6f5ec;--mut:#5a6862;--bd:#e2e6ec;--amber:#8a6d1f;--amber-t:#f8f0d8;
  max-width:1060px;margin:0 auto;padding:8px 16px 44px;color:var(--ink);
  font-family:inherit,-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased;font-variant-numeric:tabular-nums;font-size:1.6rem}
.pg-wrap *{box-sizing:border-box}
.pg-suggest{font-size:.98em;margin:.6em 0 0;color:var(--ink)}
.pg-cycle{font-size:.88em;color:var(--ink);margin:.45em 0 0}
.pg-trust{font-size:.88em;line-height:1.5;color:var(--ink);margin:.8em 0 0;padding:8px 14px;border-left:3px solid var(--gold,#c9a227);background:rgba(201,162,39,.05);max-width:66ch}
.pg-cycle strong{color:#b23b2e}
/* THE ASK. Was a button that opened the Portal modal; it is now an inline email field, because the
   modal is a context switch between "I want this" and "here is my address" and the board's whole
   audience is one-handed on a phone. Ghost binds any [data-members-form] on the page, so this is the
   theme's own footer pattern reused inline (unique ids: duplicate ids would break label/focus). */
.pg-sr{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
.pg-capture{margin:.9em 0 .3em;padding:14px 16px;border:1.5px solid var(--gold,#c9a227);border-bottom-width:3px;border-radius:12px;background:rgba(201,162,39,.06)}
.pg-capture-eb{display:block;font-size:.68em;font-weight:800;letter-spacing:.14em;text-transform:uppercase;color:#8a6d1f;margin:0 0 .35em}
.pg-capture-txt{font-size:.95em;line-height:1.4;color:var(--ink);margin:0 0 10px}
.pg-capture-txt strong{font-weight:800}
.pg-capture-free{color:#8a6d1f;font-weight:800}
.pg-capture form{display:flex;gap:8px;flex-wrap:wrap;margin:0}
.pg-capture input[type=email]{flex:1 1 190px;min-width:0;font:inherit;font-size:.92em;padding:11px 13px;border:1.5px solid #ddd6c2;border-radius:10px;background:#fff;color:var(--ink);min-height:44px}
.pg-capture button{flex:0 0 auto;font:inherit;font-size:.9em;font-weight:800;padding:11px 17px;min-height:44px;border:none;border-radius:10px;background:var(--ink);color:#fff;cursor:pointer}
.pg-capture button:hover{opacity:.9}
.pg-capture-fine{font-size:.78em;color:var(--mut);margin:8px 0 0}
.pg-capture [data-members-error]{margin:8px 0 0;font-size:.82em;color:#b23b2e;min-height:0}
.pg-capture-done{display:none;font-size:.95em;line-height:1.45;color:#0c5c3b;font-weight:700;margin:0}
.pg-capture.success form,.pg-capture.success .pg-capture-txt,.pg-capture.success .pg-capture-fine{display:none}
.pg-capture.success .pg-capture-done{display:block}
/* THE BAR. Two real defects, both of which meant it has never once been seen by a visitor:
   (1) it is appended to document.body, but --ink/--gold are declared on .pg-wrap, so background and
       button colour resolved to nothing outside that scope - an invisible bar on an invisible bar;
   (2) it animated `bottom`, which never settled here. transform is composited and always lands.
   Colours below are therefore LITERAL, not tokens: this element lives outside .pg-wrap by design. */
.pg-bar{position:fixed;left:0;right:0;bottom:0;z-index:2147481000;display:flex;align-items:center;gap:10px;
  padding:11px 14px calc(11px + env(safe-area-inset-bottom));background:#16263F;color:#F6F1E7;
  box-shadow:0 -4px 18px rgba(0,0,0,.18);border-top:2px solid #E2A43C;
  transform:translateY(110%);transition:transform .32s cubic-bezier(0.2,0,0,1)}
.pg-bar.pg-bar-on{transform:translateY(0)}
@media(prefers-reduced-motion:reduce){.pg-bar{transition:none}}
.pg-bar-txt{flex:1 1 auto;font-size:.86em;line-height:1.3}
.pg-bar-txt strong{color:#E2A43C}
.pg-bar-btn{flex:0 0 auto;padding:10px 15px;min-height:44px;display:inline-flex;align-items:center;border-radius:8px;background:#E2A43C;color:#2a2109 !important;font-weight:800;font-size:.86em;text-decoration:none;white-space:nowrap}
.pg-bar-x{flex:0 0 auto;background:none;border:none;color:#F6F1E7;opacity:.7;font-size:1.25em;line-height:1;padding:8px 10px;min-height:44px;cursor:pointer}
.pg-bar-x:hover{opacity:1}
/* Never ask a member for the email they already gave. The bar's own JS gates on the
   ghost-members-ssr cookie, which does NOT match on this theme - so a signed-in member got the bar
   shell with its CTA stripped out by the site-wide `html.tc-paid a[href*="portal/signup"]{display:none}`
   rule: a navy bar with text, a dismiss X, and no button. Gate on the same class that rule uses, in
   CSS, so it cannot race the member block that stamps the class. */
html.tc-member .pg-bar,html.tc-member .pg-capture{display:none !important}
/* THE TEACHING LINE. Every row carries a history chart and a price alert, but both live behind
   .pg-row:not(.pg-open) .pg-rh-bot{display:none} - so a first-time reader has no way to learn they
   exist. One sentence is cheaper than putting an affordance on 572 rows. */
.pg-teach{font-size:.9em;line-height:1.45;color:var(--ink);margin:.7em 0 0;padding:9px 13px;border-left:3px solid var(--gold,#c9a227);background:rgba(201,162,39,.05)}
.pg-plan-send{display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-top:10px;padding-top:10px;border-top:1px dotted var(--bd)}
.pg-plan-mailto,.pg-plan-copy{display:inline-block;padding:7px 13px;border-radius:8px;font-weight:700;font-size:.86em;text-decoration:none;border:1.5px solid var(--ink);color:var(--ink);background:#fff;cursor:pointer}
.pg-plan-mailto:hover,.pg-plan-copy:hover{background:var(--ink);color:#fff}
.pg-plan-weekly{font-size:.82em;color:var(--mut)}
.pg-plan-weekly a{font-weight:700}
.pg-suggest a{color:var(--green-d);font-weight:700;text-decoration:none;border-bottom:2px solid var(--green-t)}
.pg-suggest a:hover{border-bottom-color:var(--green)}
.pg-head h1{font-size:2em;line-height:1.12;margin:.1em 0 .12em;color:var(--ink);text-wrap:balance;letter-spacing:-.01em}
.pg-sub{font-size:1.08em;line-height:1.4;color:var(--mut);margin:.2em 0 .5em;max-width:60ch}
.pg-note{font-size:.83em;color:var(--mut);opacity:.85;margin:.2em 0 0;max-width:66ch}
/* record flags - the per-row badges (the top-of-page records band was removed 2026-08-09) */
.pg-rec{display:inline-block;margin-left:0;padding:2px 9px 2px;border-radius:999px;font-size:.6em;font-weight:800;letter-spacing:.06em;text-transform:uppercase;white-space:nowrap;vertical-align:2px}
/* recipe-ingredient rows merged into the weekly sections (2026-08-15): muted marker, not a call to action */
.pg-ri{background:#f1ede2;color:#8a6d1f;border:1px solid #e5dcc8}
.pg-rec-low{background:var(--green);color:#fff}
.pg-rec-tie{background:var(--green-t);color:var(--green-d);border:1px solid var(--green)}
.pg-rec-dip{background:#fdf8ec;color:#8a6d1f;border:1px solid #ecd9ae}
.pg-stockup{background:#e2a43c;color:#16263f}
.pg-verd-buy{background:#fff;color:var(--green-d);border:1px solid var(--green)}
.pg-verd-wait{background:#f4f6f9;color:#68748a;border:1px solid #d5dbe4}
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
.pg-rowhead{display:flex;flex-direction:column;gap:7px;margin-bottom:0;cursor:pointer}
.pg-row.pg-open .pg-rowhead{margin-bottom:10px}
.pg-rowhead:focus-visible{outline:2px solid var(--green);outline-offset:3px;border-radius:4px}
.pg-rh-top{display:flex;align-items:center;gap:8px}
.pg-rh-bot{display:flex;flex-wrap:wrap;align-items:center;gap:7px;padding-left:28px}
/* THE NAME WRAPS, IT DOES NOT CLIP. This was white-space:nowrap + text-overflow:ellipsis, which truncated
   410 of 637 names at 375px - 64% of the board. "Ground B... $5.86/lb" over "93/7 Lea... $6.17/lb" is two
   prices and no products, and the name is the one field a shopper cannot shop without.
   flex-basis 0 (not auto) is the load-bearing part: with basis auto the name's intrinsic width pushes the
   price onto its own line, so a wrapping name costs a THIRD row instead of a second. With basis 0 the name
   takes what is left after the price and wraps inside it. The store moved to its own line (see .pg-sum-s
   below) because on a 294px row it was claiming 145px beside the name, leaving 91px - wrapping into 91px is
   worse than clipping. Measured after: 0 of 637 clipped, page 51,898px -> 53,617px (+3.3%), no new nodes. */
.pg-name{font-size:1.09em;font-weight:700;color:var(--ink);flex:1 1 0;min-width:0;overflow-wrap:break-word}
.pg-unit{font-size:.72em;color:var(--mut);opacity:.8;text-transform:uppercase;letter-spacing:.05em;white-space:nowrap}
/* collapsed rows stay one clean line: name + cheapest + chevron. The unit, record/verdict badges, and the
   history/alerts pills (JS-injected) reveal only when the row is opened, so 300 items scan fast. */
.pg-row:not(.pg-open) .pg-rh-bot{display:none}
.pg-sum{margin-left:auto;flex:0 0 auto;display:inline-flex;align-items:baseline;gap:5px;white-space:nowrap}
.pg-sum-p{font-weight:800;color:var(--green-d);font-size:1.05em}
.pg-sum-s{font-size:.78em;color:var(--mut)}
.pg-sum .pg-tag-sale{font-size:.58em;margin-left:2px;align-self:center}
.pg-chev{width:8px;height:8px;border-right:2px solid var(--mut);border-bottom:2px solid var(--mut);transform:rotate(45deg);margin-left:1px;align-self:center;flex:0 0 auto;transition:transform .15s}
.pg-row.pg-open .pg-chev{transform:rotate(-135deg)}
.pg-stores{display:none;flex-wrap:wrap;gap:8px}
.pg-row.pg-open .pg-stores,.pg-wrap.pg-allopen .pg-stores{display:flex}
.pg-chip{position:relative;display:flex;flex-direction:column;gap:3px;min-width:118px;max-width:232px;padding:10px 13px 9px;border:1px solid var(--bd);border-radius:11px;background:#fcfdfc}
.pg-chip-none{background:repeating-linear-gradient(135deg,#f7f7f5,#f7f7f5 7px,#f2f2ef 7px,#f2f2ef 14px);border-style:dashed;justify-content:center}
.pg-chip-none .pg-store{opacity:.7}
.pg-none{font-size:.92em;font-weight:600;color:#8a8a80}
.pg-see-none{color:var(--accent,#2f6bb0);font-weight:600}
.pg-chip.is-best{border-color:var(--green);background:var(--green-t);box-shadow:inset 0 0 0 1px var(--green)}
.pg-best{position:absolute;top:-9px;left:11px;background:var(--green);color:#fff;font-size:.6em;font-weight:700;letter-spacing:.06em;text-transform:uppercase;padding:2px 8px;border-radius:999px}
.pg-store{font-size:.8em;font-weight:600;color:var(--mut)}
.pg-chip.is-best .pg-store{color:var(--green-d)}
.pg-price{font-size:1.14em;font-weight:800;color:var(--ink);line-height:1.1}
.pg-meta{display:flex;align-items:center;gap:6px;flex-wrap:wrap;min-height:14px}
.pg-tag{font-size:.64em;color:var(--mut);text-transform:uppercase;letter-spacing:.04em}
.pg-tag-sale{color:#b23b2e;font-weight:700}
.pg-note2{font-size:.62em;color:var(--amber);background:var(--amber-t);padding:1px 6px;border-radius:5px;font-weight:600}
.pg-sale{display:inline-block;align-self:flex-start;margin-top:4px;font-size:.62em;font-weight:700;color:#b23b2e;background:rgba(178,59,46,.09);border:1px solid rgba(178,59,46,.22);padding:1px 6px;border-radius:5px;white-space:nowrap}
.pg-see{margin-top:5px;font-size:.68em;font-weight:700;color:var(--green-d);text-decoration:none;border-top:1px dotted var(--bd);padding-top:5px}
.pg-see-search{color:var(--mut);font-weight:600}.pg-see-search:hover{color:var(--green-d)}
.pg-itemname{display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;overflow-wrap:break-word;margin-top:5px;font-size:.66em;font-weight:500;color:var(--mut);border-top:1px dotted var(--bd);padding-top:5px;line-height:1.3}
.pg-adonly{display:inline-block;align-self:flex-start;font-size:.6em;font-weight:600;color:var(--mut);border:1px solid var(--bd);border-radius:3px;padding:1px 5px;margin-top:4px;white-space:nowrap;opacity:.85}
a.pg-adonly{text-decoration:none;cursor:pointer}
a.pg-adonly:hover,a.pg-adonly:focus{opacity:1;border-color:var(--mut)}
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
@media(max-width:560px){.pg-wrap{font-size:1.4rem}.pg-head h1{font-size:1.55em}.pg-chip{min-width:calc(50% - 4px);flex:1 1 calc(50% - 4px);max-width:none}
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
.pg-trip-clear{background:transparent;color:#c8d2df;border:none;cursor:pointer;font-family:inherit;font-size:.85em;text-decoration:underline;white-space:nowrap;flex-shrink:0}
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

# =====================================================================================================
# THE ELITE LAYER STYLESHEET (2026-07-31)
# =====================================================================================================
# Rides AFTER the base sheet above so a later rule wins, and every selector is inside .pg-wrap or one of
# the overlay classes, so nothing here can leak into the rest of the Ghost theme.
$eliteCss = '<style>' + (Compress-TcCss ((Get-TcTokenCss -Scope '.pg-wrap' -Parts @('type','depth','navy','money','focus','touch','stack','receipt','ledger','motion','check','skel')) + @'
/* ---- P0-2 PERFORMANCE: skip layout and paint for offscreen categories. This is the 80/20 for the
   Ctrl+End renderer freeze and the white flash on fast scroll. contain-intrinsic-size:auto lets the
   browser REMEMBER each section's real height after first render, so scroll position stays stable
   (a fixed guess is what makes content-visibility jump). Search must un-skip a matching section, which
   it does: .pg-hide is display:none, and a visible section is always laid out when it enters view. ---- */
.pg-wrap .pg-cat{content-visibility:auto;contain-intrinsic-size:auto 3000px}
.pg-wrap .pg-row,.pg-wrap .pg-cat{scroll-margin-top:96px}
/* The masthead's navy band, tally, stat line and drop chip were styled here; band removed 2026-08-09. */
.pg-wrap .pg-how{margin:.7em 0 0;font-size:.88em}
.pg-wrap .pg-how summary{cursor:pointer;font-weight:700;color:#1E3A5F;padding:6px 0;min-height:36px}
.pg-wrap .pg-how p{margin:.4em 0 0}
/* ---- LEDGER ROWS: index-tab category heads, warm hairlines, dotted leaders, a store dot ---- */
.pg-wrap .pg-cath{position:relative;border-top:3px double #16263F;border-bottom:none;padding:12px 0 6px 14px;margin:34px 0 2px}
.pg-wrap .pg-cath::before{content:'';position:absolute;left:0;top:14px;width:5px;height:20px;border-radius:0 3px 3px 0;background:#E2A43C}
.pg-wrap .pg-cath-n{background:#16263F;color:#F6F1E7;border-radius:999px;padding:2px 10px;margin-left:10px;font-size:.62em;font-weight:700;letter-spacing:.04em}
.pg-wrap .pg-row{padding:13px 0 14px;border-bottom:1px solid #eee9dc}
/* THE ROW HEAD IS TWO LINES: name + price, then the store beneath the name.
   The dotted leader that used to live here is gone. It was a repeating dot background pinned to one
   baseline (background-position:0 .95em), so it could not follow a name onto a second line - and the name
   has to wrap (see .pg-name). The opaque backgrounds below were only ever there to mask that leader; they
   stay because they also keep the name and price legible if a row ever gains a tint, and cost nothing.
   margin-left:auto is dropped from THIS rule on purpose: in a wrapping flex row an auto margin eats all the
   free space on the line, which shoved the price onto a third row. The base .pg-sum rule still carries it,
   but it resolves to zero here because .pg-name{flex:1 1 0} has already absorbed the free space - and that
   same grow is what right-aligns the price, so the auto margin is not needed at phone widths. */
.pg-wrap .pg-rh-top{gap:1px 9px;flex-wrap:wrap;position:relative}
.pg-wrap .pg-name,.pg-wrap .pg-sum,.pg-wrap .pg-pickl,.pg-wrap .pg-flag{background:#fff}
.pg-wrap .pg-sum{gap:8px;padding-left:6px;order:2;flex:0 0 auto}
.pg-wrap .pg-name{padding-right:6px}
/* flex:0 0 100% is what puts the store on its own line; the left pad lines it up under the name rather
   than under the checkbox. order:3 keeps it after the price in the flex ordering, i.e. on the second line. */
.pg-wrap .pg-sum-s{display:inline-flex;align-items:center;gap:5px;order:3;flex:0 0 100%;padding-left:27px}
.pg-wrap .pg-sum-s::before{content:'';width:8px;height:8px;border-radius:999px;background:var(--sd,#5a6862);display:inline-block;flex:none}
.pg-wrap .pg-sum-p{order:2;font-variant-numeric:tabular-nums;font-weight:750}
.pg-wrap .pg-flag{flex:none;color:#8a6d1f;border:1px solid #E2A43C;border-radius:4px;padding:1px 7px;font-size:.6em;font-weight:800;letter-spacing:.06em;text-transform:uppercase}
.pg-wrap .pg-rh-bot{padding-left:33px}
/* DESKTOP KEEPS THE ONE-LINE LEDGER. The second line exists to buy the name width on a 294px phone row; a
   700px+ row has width to spare, so there the store returns beside the price and the dotted leader comes
   back with it. This block has to sit AFTER the .pg-wrap rules above - the @media(min-width:700px) block
   further up uses bare .pg-name/.pg-chip selectors and would lose to .pg-wrap on specificity. */
@media(min-width:700px){
.pg-wrap .pg-rh-top{flex-wrap:nowrap;background-image:linear-gradient(to right,#cfc7b0 34%,rgba(0,0,0,0) 0);background-size:6px 1px;background-repeat:repeat-x;background-position:0 .95em}
.pg-wrap .pg-sum{margin-left:auto}
.pg-wrap .pg-sum-s{order:1;flex:0 0 auto;padding-left:0}
}
/* THE CHEVRON, at zero extra nodes */
.pg-wrap .pg-rh-top::after{content:'';flex:none;width:7px;height:7px;border-right:2px solid var(--mut);border-bottom:2px solid var(--mut);transform:rotate(45deg) translate(-2px,-2px);transition:transform .15s}
.pg-wrap .pg-row.pg-open .pg-rh-top::after{transform:rotate(-135deg) translate(-2px,-2px)}
/* THE 24px CHECKBOX, at zero extra nodes: a real input, appearance stripped, check drawn in CSS */
.pg-wrap .pg-pickl{margin-right:0;flex:none;display:inline-flex}
.pg-wrap .pg-pick{-webkit-appearance:none;appearance:none;position:relative;width:24px;height:24px;border:2px solid var(--ink);border-radius:6px;background:#fff;cursor:pointer;margin:0;flex:none}
.pg-wrap .pg-pick:checked{border-color:#8a6d1f;background:#fffdf6}
.pg-wrap .pg-pick::after{content:'';position:absolute;left:6px;top:2px;width:6px;height:12px;border:solid #8a6d1f;border-width:0 2.5px 2.5px 0;transform:rotate(45deg) scale(.2);opacity:0}
.pg-wrap .pg-pick:checked::after{opacity:1;transform:rotate(45deg) scale(1)}
@media (prefers-reduced-motion:no-preference){.pg-wrap .pg-pick::after{transition:transform 140ms cubic-bezier(0.2,0,0,1),opacity 100ms cubic-bezier(0.2,0,0,1)}
  .pg-wrap .pg-row.pg-picked{animation:pgPick 520ms cubic-bezier(0.2,0,0,1)}
  @keyframes pgPick{0%{background-color:rgba(226,164,60,.16)}100%{background-color:transparent}}}
/* ---- STICKY BAR ON A DIET: one solid line, full column width, no translucency (which is what let rows
   ghost through its right edge at 1568px), and the rail keeps one line tall on every width. ---- */
.pg-wrap .pg-filters{background:#fff;backdrop-filter:none;padding:10px 0 9px;gap:8px;border-bottom:1px solid #e7e2d4;width:100%}
.pg-wrap .pg-pills{flex-wrap:nowrap;overflow-x:auto;-webkit-overflow-scrolling:touch;scrollbar-width:none;min-width:0;max-width:100%;contain:inline-size;
  -webkit-mask-image:linear-gradient(90deg,#000 0,#000 calc(100% - 26px),transparent 100%);mask-image:linear-gradient(90deg,#000 0,#000 calc(100% - 26px),transparent 100%)}
.pg-wrap .pg-pills::-webkit-scrollbar{display:none}
.pg-wrap .pg-fbtn{white-space:nowrap;flex:0 0 auto;min-height:40px}
.pg-wrap .pg-fbtn.is-here{border-color:#E2A43C;color:#8a6d1f}
.pg-wrap .pg-search{max-width:none;flex:1}
/* The chalkboard skin dressed the price-records band; the band was removed 2026-08-09, and the masthead is
   now the ONE dark panel on this page. */
/* ---- SPARKLINE ---- */
.pg-wrap .pg-spark{display:inline-flex;align-items:center;gap:9px;flex-wrap:wrap;width:100%;margin-top:6px}
.pg-wrap .pg-spark svg{flex:none}
.pg-wrap .pg-spark-l{font-size:.72em;font-weight:700;color:#8a6d1f;font-variant-numeric:tabular-nums}
.pg-wrap .pg-spark-c{font-size:.68em;color:var(--mut)}
/* ---- TRIP BAR: a readout, not just a counter ---- */
.pg-wrap .pg-tripbar{left:50%;right:auto;padding-bottom:calc(10px + env(safe-area-inset-bottom))}
.pg-wrap .pg-trip-txt{display:flex;flex-direction:column;line-height:1.25;min-width:0}
.pg-wrap .pg-trip-sub{font-size:.72em;color:#b9c4d4;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pg-wrap .pg-demo{display:inline-block;margin-top:8px;background:#E2A43C;color:#16263F;border:none;border-radius:999px;padding:7px 15px;min-height:40px;font-size:.92em;font-weight:800;cursor:pointer;font-family:inherit}
.pg-wrap .pg-resume,.pg-resume{position:fixed;left:50%;transform:translateX(-50%);bottom:calc(72px + env(safe-area-inset-bottom));z-index:2147480000;
  display:flex;align-items:center;gap:10px;background:#fffdf6;border:1px solid #e7e2d4;border-radius:999px;padding:8px 14px;box-shadow:0 8px 24px rgba(22,38,63,.18);font-size:14px;color:#16263F}
.pg-resume button{background:none;border:none;color:#8a6d1f;font-weight:700;text-decoration:underline;cursor:pointer;font-family:inherit;min-height:32px}
/* ---- TRIP RECEIPTS ---- */
.pg-wrap .pg-plan-cmp{margin:6px 0 12px;font-size:.9em;line-height:1.5;color:var(--ink);padding:9px 12px;background:#fffdf6;border:1px solid #e9dcc0;border-left:4px solid #E2A43C;border-radius:0 10px 10px 0}
.pg-wrap .pg-plan-cmp b{color:#0c5c3b;font-variant-numeric:tabular-nums}
.pg-wrap .pg-rcs{display:flex;gap:14px;flex-wrap:wrap;margin:10px 0 4px}
.pg-wrap .pg-rc{position:relative;flex:1 1 250px;min-width:0;background:#fffdf6;border:1px solid #e7e2d4;border-radius:2px;padding:0 14px 12px;box-shadow:0 2px 10px rgba(22,38,63,.07)}
.pg-wrap .pg-rc::before,.pg-wrap .pg-rc::after{content:'';position:absolute;left:0;right:0;height:8px;
  background:linear-gradient(-45deg,transparent 0 5.66px,#fffdf6 0) 0 0/16px 16px repeat-x,linear-gradient(45deg,transparent 0 5.66px,#fffdf6 0) 0 0/16px 16px repeat-x}
.pg-wrap .pg-rc::before{top:-8px;transform:scaleY(-1)}
.pg-wrap .pg-rc::after{bottom:-8px}
.pg-wrap .pg-rc-band{height:4px;margin:0 -14px;background:var(--st)}
.pg-wrap .pg-rc-h{display:flex;align-items:baseline;justify-content:space-between;gap:8px;padding:10px 0 6px;border-bottom:1px solid #e7e2d4}
.pg-wrap .pg-rc-h b{font-size:1.02em;color:var(--ink)}
.pg-wrap .pg-rc-h span{font-size:.76em;color:var(--mut)}
.pg-wrap .pg-rc-l{list-style:none;margin:0;padding:6px 0 0}
.pg-wrap .pg-rc-l li{display:flex;align-items:flex-end;gap:6px;padding:5px 0;font-size:.9em;color:var(--ink)}
.pg-wrap .pg-rc-n{flex:0 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.pg-wrap .pg-rc-ld{flex:1 1 auto;min-width:12px;border-bottom:1px dotted #cfc7b0;transform:translateY(-.36em)}
.pg-wrap .pg-rc-p{flex:none;font-variant-numeric:tabular-nums;font-weight:750;color:#0c5c3b;font-size:.94em}
.pg-wrap .pg-rc-f{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-top:8px;padding-top:9px;border-top:3px double var(--ink);font-size:.8em;color:var(--mut)}
.pg-wrap .pg-aisle{background:#E2A43C;color:#16263F;border:none;border-radius:999px;padding:7px 14px;min-height:40px;font-size:1.05em;font-weight:800;cursor:pointer;font-family:inherit}
.pg-wrap .pg-plan-share{background:#16263F;color:#fff;border-color:#16263F}
@media(max-width:640px){
  .pg-wrap .pg-rcs{flex-wrap:nowrap;overflow-x:auto;scroll-snap-type:x mandatory;-webkit-overflow-scrolling:touch;padding-bottom:14px;contain:inline-size}
  .pg-wrap .pg-rc{flex:0 0 80vw;scroll-snap-align:center}
}
/* ---- AISLE MODE ---- */
.pg-aisle-ov{position:fixed;inset:0;z-index:2147483000;background:#fdf8ec;display:flex;flex-direction:column;overscroll-behavior:contain}
.pg-aisle-hd{display:flex;align-items:center;gap:10px;background:#16263F;color:#fff;padding:calc(12px + env(safe-area-inset-top)) 14px 12px}
.pg-aisle-hd i{width:12px;height:12px;border-radius:999px;background:var(--st);flex:none}
.pg-aisle-hd b{flex:1;font-size:17px;font-weight:800;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.pg-aisle-x{min-width:64px;min-height:44px;border:none;background:rgba(255,255,255,.14);color:#fff;border-radius:10px;font-size:15px;font-weight:800;cursor:pointer;font-family:inherit}
.pg-aisle-b{flex:1;overflow:auto;padding:6px 0 10px}
.pg-aisle-r{display:flex;align-items:center;justify-content:space-between;gap:12px;width:100%;min-height:64px;padding:10px 18px;border:none;border-bottom:1px solid #eee9dc;background:#fdf8ec;text-align:left;cursor:pointer;font-family:inherit}
.pg-aisle-t{font-size:17px;font-weight:600;color:#16263F;min-width:0;overflow:hidden;text-overflow:ellipsis}
.pg-aisle-p{font-size:24px;font-weight:800;color:#0c5c3b;font-variant-numeric:tabular-nums;white-space:nowrap}
.pg-aisle-r.is-done{background:#f2ede1}
.pg-aisle-r.is-done .pg-aisle-t{text-decoration:line-through;color:#8a94a6}
.pg-aisle-r.is-done .pg-aisle-p{color:#8a94a6}
.pg-aisle-ft{display:flex;flex-direction:column;gap:3px;padding:12px 18px calc(12px + env(safe-area-inset-bottom));background:#16263F;color:#fff}
.pg-aisle-n{font-size:16px;font-weight:800;color:#E2A43C;font-variant-numeric:tabular-nums}
.pg-aisle-note{font-size:12px;color:#b9c4d4}
/* ---- BOTTOM SHEET on phones: the expanded row becomes a sheet, cheapest first, scrim/X/back to dismiss.
   No drag physics and no drag handle: a handle that does not drag is a lie about the interface. ---- */
@media(max-width:640px){
  body.pg-sheet-on{overflow:hidden}
  .pg-sheet-scrim{position:fixed;inset:0;z-index:2147481500;background:rgba(16,27,46,.45)}
  .pg-sheet{position:fixed;left:0;right:0;bottom:0;max-height:70vh;overflow:auto;z-index:2147481600;background:#fff;border-radius:16px 16px 0 0;
    padding:14px 16px calc(16px + env(safe-area-inset-bottom));box-shadow:0 -10px 30px rgba(22,38,63,.28)}
  .pg-sheet-h{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:10px}
  .pg-sheet-h b{font-size:17px;color:#16263F}
  .pg-sheet-x{min-width:44px;min-height:44px;border:none;background:#f2ede1;color:#16263F;border-radius:10px;font-size:18px;cursor:pointer;font-family:inherit}
  .pg-sheet .pg-stores{display:flex !important;flex-wrap:wrap;gap:8px}
}
'@ + (Get-TcPrintCss))) + '</style>'

$js = @'
<script>
(function(){
  // The seven store hues, injected from the canonical registry (grocery\stores.json) at build time so the
  // dots on the rows, the receipt bands and the Aisle Mode header can never disagree with each other.
  var PG_HUE=__STORE_HUES__;
  // ---- free-email bar: slides in AFTER real scrolling (they are getting value), never for members,
  // dismiss sticks for 30 days. A bottom bar under thumb reach, not a popup - Reddit closes popups. ----
  try {
    var isMember = document.cookie.indexOf('ghost-members-ssr') > -1;
    var snooze = 0; try { snooze = parseInt(localStorage.getItem('tcBarSnooze') || '0', 10); } catch(e){}
    if (!isMember && (Date.now() - snooze) > 30*24*3600*1000) {
      var bar = document.createElement('div');
      bar.className = 'pg-bar';
      bar.innerHTML = "<span class='pg-bar-txt'><strong>Like this board?</strong> Get the updated prices every Friday, free.</span>" +
        "<a class='pg-bar-btn' href='#/portal/signup/free' data-portal='signup/free'>Email it to me</a>" +
        "<button class='pg-bar-x' aria-label='Dismiss'>&times;</button>";
      document.body.appendChild(bar);
      var shown = false;
      function maybeShow(){
        if (shown) return;
        var y = window.scrollY || document.documentElement.scrollTop;
        if (y > 2200) { shown = true; bar.classList.add('pg-bar-on'); window.removeEventListener('scroll', maybeShow); }
      }
      window.addEventListener('scroll', maybeShow, {passive:true});
      maybeShow();   // a restored scroll position (back button, deep link) fires no scroll event
      bar.querySelector('.pg-bar-x').addEventListener('click', function(){
        bar.classList.remove('pg-bar-on');
        try { localStorage.setItem('tcBarSnooze', String(Date.now())); } catch(e){}
      });
      bar.querySelector('.pg-bar-btn').addEventListener('click', function(){
        bar.classList.remove('pg-bar-on');
      });
      // Asking twice for something already given is the fastest way to look broken: once the inline
      // capture succeeds, the bar retires for good and does not come back on the next visit either.
      var cap = document.querySelector('.pg-capture');
      if (cap) {
        new MutationObserver(function(){
          if (cap.classList.contains('success')) {
            bar.classList.remove('pg-bar-on');
            try { localStorage.setItem('tcBarSnooze', String(Date.now())); } catch(e){}
          }
        }).observe(cap, {attributes:true, attributeFilter:['class']});
      }
    }
  } catch(e){}

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
  // ---- progressive disclosure: rows collapse to a one-line cheapest summary; click/tap to open all stores ----
  function pgFirstChip(row){ var cs=row.querySelectorAll('.pg-chip'); for(var i=0;i<cs.length;i++){ if(cs[i].style.display!=='none') return cs[i]; } return null; }
  function pgSummaries(){
    document.querySelectorAll('.pg-row').forEach(function(row){
      var sum=row.querySelector('.pg-sum'); if(!sum) return;
      // Chips are lazy now (fetched from board.json). When they are not in the DOM yet there is nothing to
      // re-derive from, so LEAVE the server-rendered summary alone. This used to blank it (sum.innerHTML=''),
      // which with lazy chips would wipe the cheapest price off EVERY row on load. Only rebuild from real chips.
      var c=pgFirstChip(row); if(!c){ return; }
      var p=c.querySelector('.pg-price'), s=c.querySelector('.pg-store');
      var sale=c.querySelector('.pg-tag-sale')?" <span class='pg-tag pg-tag-sale'>sale</span>":"";
      // .pg-sum now holds the PRICE only; the store is a sibling on the row head's second line. Rebuilding
      // both from one innerHTML would nest the store back inside .pg-sum and collapse the row to one line
      // again on every load and every Hide-Sam's toggle. Writing the store's textContent also keeps its
      // style='--sd:<hue>' - the old innerHTML rewrite dropped it, so the store dot silently lost its colour
      // after a recompute and every row's dot fell back to the default grey.
      sum.innerHTML="<span class='pg-sum-p'>"+(p?p.textContent:'')+"</span>"+sale;
      var st=row.querySelector('.pg-rh-top > .pg-sum-s');
      if(st&&s){ st.textContent=s.textContent; }
    });
  }
  document.querySelectorAll('.pg-rowhead').forEach(function(h){ h.setAttribute('tabindex','0'); });
  // ---- LAZY STORE CHIPS ----
  // The per-store breakdown lives in board.json (served by the feed Worker) instead of inside the post: it is
  // display:none until a row opens, so shipping it inline was ~1.1 MB of hidden markup that pushed the Ghost
  // upsert past its processing timeout (503 = the board could not publish). A row fills the instant it is
  // opened; a background pass fills the rest after first paint so everything that reads chips (the hide-Sam's
  // recompute, the trip planner, expand-all) keeps working exactly as before, just a moment later.
  var BOARD=null,_bp=null;
  var BOARD_URL='__BOARD_URL__';
  function loadBoard(){
    if(BOARD) return Promise.resolve(BOARD);
    if(!_bp){ _bp=fetch(BOARD_URL).then(function(r){ return r.ok?r.json():null; }).then(function(j){ BOARD=j||{}; return BOARD; }).catch(function(){ _bp=null; return null; }); }
    return _bp;
  }
  function pgFillRow(row){
    var box=row.querySelector('.pg-stores[data-lazy]'); if(!box) return false;
    // data-ck, not data-id: 54 ids render on BOTH a weekly-staple row and a recipe row with different units,
    // so each row carries its own feed key ('<id>' for the staple, '<id>::r' for the recipe row).
    var ck=box.getAttribute('data-ck')||row.getAttribute('data-id');
    if(BOARD&&BOARD[ck]){ box.innerHTML=BOARD[ck]; box.removeAttribute('data-lazy'); return true; }
    return false;
  }
  var _filledAll=false;
  function pgFillAll(){
    if(_filledAll) return Promise.resolve(true);
    return loadBoard().then(function(b){
      if(!b) return false;
      document.querySelectorAll('.pg-row').forEach(function(r){ pgFillRow(r); });
      _filledAll=true;
      return true;
    });
  }
  // ---- BOTTOM SHEET at phone widths -------------------------------------------------------------------
  // Desktop keeps inline expansion. On a phone the seven store cards open as a sheet over the board, so the
  // rows around them do not jump 400px and lose the reader's place. Dismiss is scrim, X, or hardware back,
  // and that is all: no drag physics, and no drag handle, because a handle that does not drag is a lie.
  var _sheet=null;
  function sheetClose(){
    if(!_sheet) return;
    try{ _sheet.row.appendChild(_sheet.box); }catch(e){}
    _sheet.box.classList.remove('pg-sheet-open');
    try{ document.body.removeChild(_sheet.el); document.body.removeChild(_sheet.scrim); }catch(e){}
    document.body.classList.remove('pg-sheet-on');
    if(window.TC&&window.TC.mode) window.TC.mode(false);
    if(_sheet.untrap) _sheet.untrap();
    var t=_sheet.trigger; _sheet=null;
    try{ if(t&&t.focus) t.focus(); }catch(e){}
  }
  function sheetOpen(row, head){
    var box=row.querySelector('.pg-stores'); if(!box) return;
    var scrim=document.createElement('div'); scrim.className='pg-sheet-scrim';
    var el=document.createElement('div'); el.className='pg-sheet'; el.setAttribute('role','dialog'); el.setAttribute('aria-modal','true');
    var nm=row.querySelector('.pg-name');
    el.innerHTML='<div class="pg-sheet-h"><b></b><button type="button" class="pg-sheet-x" aria-label="Close">&times;</button></div>';
    el.querySelector('.pg-sheet-h b').textContent=nm?nm.textContent:'';
    el.appendChild(box);
    document.body.appendChild(scrim); document.body.appendChild(el);
    document.body.classList.add('pg-sheet-on');
    if(window.TC&&window.TC.mode) window.TC.mode(true);
    _sheet={el:el,scrim:scrim,box:box,row:row,trigger:head,untrap:(window.TC&&window.TC.trap)?window.TC.trap(el,sheetClose):null};
    scrim.addEventListener('click',sheetClose);
    el.querySelector('.pg-sheet-x').addEventListener('click',sheetClose);
    try{ history.pushState({tcSheet:1},'',location.pathname+location.search); }catch(e){}
    window.addEventListener('popstate',function h(){ window.removeEventListener('popstate',h); if(_sheet) sheetClose(); });
  }
  function isPhone(){ try{ return window.matchMedia('(max-width:640px)').matches; }catch(e){ return false; } }
  function pgToggle(head){
    var row=head.closest('.pg-row'); if(!row) return;
    if(isPhone()){
      if(_sheet&&_sheet.row===row){ sheetClose(); return; }
      if(_sheet) sheetClose();
      row.classList.add('pg-open');
      var open=function(){ sheetOpen(row, head); };
      if(row.querySelector('.pg-stores[data-lazy]')){ loadBoard().then(function(){ pgFillRow(row); open(); }); } else { open(); }
      return;
    }
    row.classList.toggle('pg-open');
    if(row.classList.contains('pg-open')&&row.querySelector('.pg-stores[data-lazy]')){ loadBoard().then(function(){ pgFillRow(row); }); }
  }
  document.addEventListener('click',function(e){
    if(e.target.closest('.pg-pickl,.pg-pick,.pg-alertp,.pg-histp,.pg-see,.pg-hx,a,button,input,label')) return;
    var head=e.target.closest('.pg-rowhead'); if(head){ pgToggle(head); }
  });
  document.addEventListener('keydown',function(e){
    if((e.key==='Enter'||e.key===' ')&&e.target.classList&&e.target.classList.contains('pg-rowhead')){ e.preventDefault(); pgToggle(e.target); }
  });
  var pgWrap=document.querySelector('.pg-wrap'), pgEA=document.getElementById('pg-expandall');
  if(pgEA&&pgWrap){ pgEA.addEventListener('change',function(){ if(pgEA.checked){ pgFillAll(); } pgWrap.classList.toggle('pg-allopen',pgEA.checked); }); }
  // fill everything once the page is idle, so chip-dependent features are ready before a human can reach them
  if(window.requestIdleCallback){ requestIdleCallback(function(){ pgFillAll(); },{timeout:3000}); } else { setTimeout(function(){ pgFillAll(); },1200); }
  pgSummaries();
  // hide Sam's Club: drop its chips, then re-flag the cheapest per row. (It used to recount the scoreboard
  // too; that band was removed 2026-08-09, so the per-row re-flag plus pgSummaries is the whole job.)
  var SAMS="Sam's Club";
  var tg=document.getElementById('pg-hidesams');
  function recompute(){
    var hide=tg.checked;
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
      }
    });
    pgSummaries();
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
        var prices={}, disp={};
        row.querySelectorAll('.pg-chip').forEach(function(c){
          var pu=parseFloat(c.getAttribute('data-pu')), st=c.getAttribute('data-store');
          if(st && pu>0 && (!(st in prices) || pu<prices[st])){
            prices[st]=pu;
            // Keep the FORMATTED price too. A trip receipt that prints a bare "4.98" next to an item is a
            // basis lie waiting to happen: these per-unit numbers are $/lb, $/dozen, cents/oz and each,
            // and they are only comparable down a column, never across one. The chip already carries the
            // number with its unit attached, so the receipt reuses that string rather than reformatting.
            var pEl=c.querySelector('.pg-price'); disp[st]=pEl?pEl.textContent:'';
          }
        });
        tripSel[rid]={name:row.querySelector('.pg-name').textContent,prices:prices,disp:disp,id:row.getAttribute('data-id')||rid};
      } else { delete tripSel[rid]; }
      tripBar(); tripSave();
    });
  });
  // ---- PERSISTENCE. Picks survive a reload, keyed by commodity id AND the board's week stamp. A list
  // saved against last week's prices is not a saved list, it is a set of stale claims about re-priced
  // rows, so a prior-week list is DISCARDED rather than restored. ----
  var TRIP_WEEK='__WEEK__', TRIP_KEY='tcTrip';
  function tripSave(){
    try{
      var ids=[]; for(var k in tripSel){ ids.push(tripSel[k].id); }
      if(!ids.length){ localStorage.removeItem(TRIP_KEY); return; }
      localStorage.setItem(TRIP_KEY, JSON.stringify({w:TRIP_WEEK, ids:ids}));
    }catch(e){}
  }
  function tripRestore(){
    var saved=null;
    try{ saved=JSON.parse(localStorage.getItem(TRIP_KEY)||'null'); }catch(e){}
    if(!saved||!saved.ids||!saved.ids.length) return;
    if(saved.w!==TRIP_WEEK){ try{ localStorage.removeItem(TRIP_KEY); }catch(e){} return; }
    var want={}; saved.ids.forEach(function(i){ want[i]=1; });
    var n=0;
    document.querySelectorAll('.pg-row[data-id]').forEach(function(row){
      if(!want[row.getAttribute('data-id')]) return;
      var cb=row.querySelector('.pg-pick'); if(!cb||cb.checked) return;
      cb.checked=true; cb.dispatchEvent(new Event('change')); n++;
    });
    if(!n) return;
    var pill=document.createElement('div');
    pill.className='pg-resume';
    pill.innerHTML='<span>Your list from earlier is loaded, <b>'+n+'</b> item'+(n===1?'':'s')+'</span><button type="button">Clear</button>';
    document.body.appendChild(pill);
    pill.querySelector('button').addEventListener('click',function(){
      document.querySelectorAll('.pg-pick').forEach(function(c){ if(c.checked){ c.checked=false; c.dispatchEvent(new Event('change')); } });
      pill.parentNode.removeChild(pill);
    });
    setTimeout(function(){ if(pill.parentNode) pill.parentNode.removeChild(pill); }, 12000);
  }
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
      byStore[ms].push({n:it.name, d:(it.disp&&it.disp[ms])?it.disp[ms]:''});
      if(m===gmin[i]){ atBest++; }
    });
    var html='<p class="pg-plan-sum">Your best '+best.combo.length+'-store trip gets the cheapest available price on <b>'+atBest+' of '+items.length+'</b> selected items.</p>';
    // THE ONE-STORE COMPARISON, honestly. These per-unit prices are $/lb, $/dozen, cents/oz and each, so
    // there is no dollar total to subtract and no "you keep $5.20" to print: a sum across mixed units is
    // not a number. What IS comparable is COVERAGE, so that is what the comparison says. The line is
    // dropped entirely when no single store prices the whole basket, rather than inventing a denominator.
    var soloBest=null, soloStore=null, soloFull=false;
    stores.forEach(function(st){
      var cover=0, hit=0;
      items.forEach(function(it,i){ var p=it.prices[st]; if(p>0){ cover++; if(p===gmin[i]) hit++; } });
      if(cover===items.length && (soloBest===null||hit>soloBest)){ soloBest=hit; soloStore=st; soloFull=true; }
    });
    if(soloFull && best.combo.length>1 && atBest>soloBest){
      html+='<p class="pg-plan-cmp">One store can cover this whole list: <b>'+esc(soloStore)+'</b>, at the cheapest price on <b>'+soloBest+' of '+items.length+'</b>. This '+best.combo.length+'-store split gets you <b>'+atBest+'</b>. That difference is the whole point of the board.</p>';
    }
    // RECEIPT PER STORE. Tear edges, the store's own colour as the top band, dotted leaders, a subtotal
    // rule. On a phone the receipts become a horizontal snap rail so a 4-store trip is four swipes, not
    // four screens of scrolling.
    html+='<div class="pg-rcs">';
    best.combo.slice().sort(function(a,b){return byStore[b].length-byStore[a].length;}).forEach(function(st){
      if(byStore[st].length===0) return;
      html+='<div class="pg-rc" style="--st:'+ (PG_HUE[st]||'#5a6862') +'"><div class="pg-rc-band"></div><div class="pg-rc-h"><b>'+esc(st)+'</b><span>'+byStore[st].length+(byStore[st].length===1?' item':' items')+'</span></div><ul class="pg-rc-l">';
      byStore[st].forEach(function(o){ html+='<li><span class="pg-rc-n">'+esc(o.n)+'</span><span class="pg-rc-ld"></span><span class="pg-rc-p">'+esc(o.d)+'</span></li>'; });
      html+='</ul><div class="pg-rc-f"><span>'+byStore[st].length+' to pick up</span><button type="button" class="pg-aisle" data-store="'+esc(st)+'">Shop this store</button></div></div>';
    });
    html+='</div>';
    if(uncovered.length){ html+='<p class="pg-plan-un">Not sold at these stores: '+uncovered.map(function(u){return esc(u);}).join(', ')+'</p>'; }
    // END-OF-JOB CAPTURE. The list lives in this tab and dies with it - "send it to my phone" is a receipt
    // the shopper WANTS, not a marketing ask. mailto/copy need no backend and cannot be abused as a mail
    // relay; the weekly line beside them is the habit hook.
    var listTxt='My Thrifty Crew shopping trip ('+new Date().toLocaleDateString()+')\n';
    best.combo.slice().sort(function(a,b){return byStore[b].length-byStore[a].length;}).forEach(function(st){
      if(byStore[st].length===0) return;
      listTxt+='\n'+st.toUpperCase()+'\n'; byStore[st].forEach(function(o){ listTxt+='  - '+o.n+(o.d?('  '+o.d):'')+'\n'; });
    });
    listTxt+='\nPrices checked this morning: https://www.thriftycrew.com/omaha-grocery-prices/';
    // the share sheet is capped: past ~1,500 characters iOS silently truncates a share payload, and a
    // half a shopping list is worse than a link to the whole one
    if(listTxt.length>1500){ listTxt=listTxt.slice(0,1400).replace(/\n[^\n]*$/,'')+'\n...and more at https://www.thriftycrew.com/omaha-grocery-prices/'; }
    html+='<div class="pg-plan-send">'+
      (navigator.share?'<button class="pg-plan-copy pg-plan-share" id="pg-plan-share">Share this list</button>':'')+
      '<a class="pg-plan-mailto" href="mailto:?subject='+encodeURIComponent('My shopping trip - Thrifty Crew')+'&body='+encodeURIComponent(listTxt)+'">Email me this list</a>'+
      '<button class="pg-plan-copy" id="pg-plan-copy">Copy list</button>'+
      '<span class="pg-plan-weekly">Want the whole board every Friday? <a href="#/portal/signup/free" data-portal="signup/free">Free email &rarr;</a></span></div>';
    document.getElementById('pg-plan-out').innerHTML=html;
    var cpBtn=document.getElementById('pg-plan-copy');
    if(cpBtn){ cpBtn.addEventListener('click',function(){
      try { navigator.clipboard.writeText(listTxt).then(function(){ cpBtn.textContent='Copied!'; setTimeout(function(){cpBtn.textContent='Copy list';},2000); }); }
      catch(e){ cpBtn.textContent='Press Ctrl+C'; }
    }); }
    var shBtn=document.getElementById('pg-plan-share');
    if(shBtn){ shBtn.addEventListener('click',function(){ try{ navigator.share({title:'My shopping trip',text:listTxt}); }catch(e){} }); }
    // AISLE MODE. Built at tap time from the split we just solved: zero nodes until someone is standing
    // in a store, and zero network once it is open.
    document.querySelectorAll('.pg-aisle').forEach(function(b){
      b.addEventListener('click',function(){ aisle(b.getAttribute('data-store'), byStore[b.getAttribute('data-store')]); });
    });
    lastK=k;
  }
  // ---- AISLE MODE ------------------------------------------------------------------------------------
  // Giant tap rows, a progress footer, a wake lock so the screen does not sleep in the aisle, and check
  // state saved per store per board week so a reload mid-shop resumes exactly where you were. Everything
  // it needs is already in memory: it makes no network request at all once open, which is the point,
  // because store wifi is where a shopping list goes to die.
  function aisle(store, list){
    if(!list||!list.length) return;
    var key='tcAisle:'+TRIP_WEEK+':'+store, done={};
    try{ done=JSON.parse(localStorage.getItem(key)||'{}')||{}; }catch(e){}
    var ov=document.createElement('div'); ov.className='pg-aisle-ov'; ov.setAttribute('role','dialog'); ov.setAttribute('aria-modal','true');
    ov.innerHTML='<div class="pg-aisle-hd" style="--st:'+(PG_HUE[store]||'#5a6862')+'"><i></i><b></b><button type="button" class="pg-aisle-x" aria-label="Close">Done</button></div>'
      +'<div class="pg-aisle-b"></div>'
      +'<div class="pg-aisle-ft"><span class="pg-aisle-n"></span><span class="pg-aisle-note">Works with no signal. Your checkmarks are saved on this phone.</span></div>';
    ov.querySelector('.pg-aisle-hd b').textContent=store;
    document.body.appendChild(ov);
    if(window.TC&&window.TC.mode) window.TC.mode(true);
    if(window.TC&&window.TC.wake) window.TC.wake(true);
    var untrap=(window.TC&&window.TC.trap)?window.TC.trap(ov,close):function(){};
    function draw(){
      var b=ov.querySelector('.pg-aisle-b'), h='';
      list.forEach(function(o,i){
        h+='<button type="button" class="pg-aisle-r'+(done[i]?' is-done':'')+'" data-i="'+i+'"><span class="pg-aisle-t">'+esc(o.n)+'</span><span class="pg-aisle-p">'+esc(o.d)+'</span></button>';
      });
      b.innerHTML=h;
      var n=0; list.forEach(function(o,i){ if(done[i]) n++; });
      ov.querySelector('.pg-aisle-n').textContent=n+' of '+list.length+' picked up';
      b.querySelectorAll('.pg-aisle-r').forEach(function(r){
        r.addEventListener('click',function(){
          var i=r.getAttribute('data-i');
          done[i]=!done[i];
          try{ localStorage.setItem(key,JSON.stringify(done)); }catch(e){}
          if(window.TC&&window.TC.tap) window.TC.tap(10);
          draw();
        });
      });
    }
    function close(){
      try{ document.body.removeChild(ov); }catch(e){}
      if(window.TC&&window.TC.mode) window.TC.mode(false);
      if(window.TC&&window.TC.wake) window.TC.wake(false);
      untrap();
    }
    ov.querySelector('.pg-aisle-x').addEventListener('click',close);
    // hardware back closes the overlay instead of leaving the page mid-shop
    try{ history.pushState({tcAisle:1},'',location.pathname+location.search+'#aisle'); }catch(e){}
    window.addEventListener('popstate',function h(){ window.removeEventListener('popstate',h); if(document.body.contains(ov)) close(); });
    draw();
  }

  // ---- THE DEMO BASKET -------------------------------------------------------------------------------
  // The trip planner is the best thing on this page and it opens empty, which means a first-time visitor
  // has to do fifteen taps of work before it can show them anything. One tap checks a curated staples
  // basket, drives the SAME solver, and scrolls to the answer. Ids come from the build (which fails if
  // coverage drops), so this can never quietly demo a basket the board no longer prices.
  var DEMO_IDS=__DEMO_IDS__;
  var demoBtn=document.getElementById('pg-demo');
  if(demoBtn && DEMO_IDS.length){
    demoBtn.addEventListener('click',function(){
      var want={}; DEMO_IDS.forEach(function(i){ want[i]=1; });
      pgFillAll().then(function(){
        var n=0;
        document.querySelectorAll('.pg-row[data-id]').forEach(function(row){
          if(!want[row.getAttribute('data-id')]) return;
          var cb=row.querySelector('.pg-pick'); if(!cb||cb.checked) return;
          cb.checked=true; cb.dispatchEvent(new Event('change')); n++;
        });
        if(!n) return;
        var stores=tripStores(); var kk=Math.min(2,stores.length);
        if(kk>0){ tripSolve(kk); tripMarkK(kk); }
        var box=document.getElementById('pg-tripbox'); if(box){ box.scrollIntoView({behavior:'smooth',block:'start'}); }
      });
    });
  }

  // ---- THE LIVE TICKER in the floating bar -----------------------------------------------------------
  // It calls tripSolve's OWN store split, not a parallel sum. There is deliberately no dollar total here:
  // see the basis note in tripSolve. What it reports is what the solver actually knows.
  var tickT=null;
  function tick(){
    var n=tripN(), el=document.getElementById('pg-trip-sub');
    if(!el) return;
    if(n===0){ el.textContent=''; return; }
    var stores=tripStores();
    el.textContent=stores.length?('cheapest across '+Math.min(2,stores.length)+' stores'):'';
  }
  var _tripBarOrig=tripBar;
  tripBar=function(){ _tripBarOrig.apply(null,arguments); clearTimeout(tickT); tickT=setTimeout(tick,300); };

  // ---- SPARKLINES in the expanded panel ---------------------------------------------------------------
  // 23 weeks of tracked lows as a ~110x28 polyline, drawn from the SAME lazy price-history fetch the
  // history pill uses. Suppressed under 6 weeks, because a three-point line is a shape, not a trend.
  function spark(row){
    var id=row.getAttribute('data-id'); if(!id) return;
    if(row.querySelector('.pg-spark')) return;
    var H=window.__tcHist; if(!H||!H.has(id)) return;
    var slot=row.querySelector('.pg-rh-bot'); if(!slot) return;
    H.load().then(function(){
      var d=H.get(id); if(!d) return;
      // the history payload keys vary by generation; take the first array of {w,p}-ish points we find
      var pts=null;
      for(var k in d){ if(Object.prototype.toString.call(d[k])==='[object Array]' && d[k].length && typeof d[k][0]==='object'){ pts=d[k]; break; } }
      if(!pts||pts.length<6) return;
      var vals=[], labs=[];
      pts.forEach(function(p){
        var v=null,l='';
        for(var kk in p){ if(typeof p[kk]==='number'&&v===null) v=p[kk]; if(typeof p[kk]==='string'&&!l) l=p[kk]; }
        if(v!==null&&v>0){ vals.push(v); labs.push(l); }
      });
      if(vals.length<6) return;
      var mn=Math.min.apply(null,vals), mx=Math.max.apply(null,vals), rng=(mx-mn)||1;
      var W=110,Hh=28,step=W/(vals.length-1), pathPts=[];
      vals.forEach(function(v,i){ pathPts.push((i*step).toFixed(1)+','+(Hh-2-((v-mn)/rng)*(Hh-6)).toFixed(1)); });
      var lowI=vals.indexOf(mn);
      var lx=(lowI*step).toFixed(1), ly=(Hh-2-((mn-mn)/rng)*(Hh-6)).toFixed(1);
      var wrap=document.createElement('span');
      wrap.className='pg-spark';
      wrap.innerHTML='<svg width="'+W+'" height="'+Hh+'" viewBox="0 0 '+W+' '+Hh+'" aria-hidden="true"><polyline points="'+pathPts.join(' ')+'" fill="none" stroke="#1E3A5F" stroke-width="1.5" stroke-linejoin="round" stroke-linecap="round"/><circle cx="'+lx+'" cy="'+ly+'" r="2.6" fill="#E2A43C"/></svg>'
        +'<span class="pg-spark-l">Record: '+(mn<1?(Math.round(mn*1000)/10+'Â¢'):('$'+mn.toFixed(2)))+(labs[lowI]?(', '+labs[lowI]):'')+'</span>'
        +'<span class="pg-spark-c">best price in Omaha, weekly</span>';
      slot.appendChild(wrap);
    });
  }
  document.addEventListener('click',function(e){
    var head=e.target.closest('.pg-rowhead'); if(!head) return;
    var row=head.closest('.pg-row');
    if(row&&row.classList.contains('pg-open')) setTimeout(function(){ spark(row); },0);
  });

  // ---- SCROLL-SYNCED CATEGORY RAIL --------------------------------------------------------------------
  // One observer marks the chip for whatever section you are actually in and centres it in the rail. It
  // scrolls the CONTAINER, never scrollIntoView, because scrollIntoView on a horizontal rail also nudges
  // the page vertically and the board then fights the reader for the scroll position.
  (function(){
    var rail=document.querySelector('.pg-pills'); if(!rail||!('IntersectionObserver' in window)) return;
    var map={};
    rail.querySelectorAll('.pg-fbtn[data-cats]').forEach(function(b){
      (b.getAttribute('data-cats')||'').split('|').forEach(function(c){ if(c) map[c]=b; });
    });
    var io=new IntersectionObserver(function(es){
      es.forEach(function(en){
        if(!en.isIntersecting) return;
        var b=map[en.target.getAttribute('data-cat')||'']; if(!b) return;
        rail.querySelectorAll('.pg-fbtn').forEach(function(x){ x.classList.remove('is-here'); });
        b.classList.add('is-here');
        var r=b.getBoundingClientRect(), rr=rail.getBoundingClientRect();
        rail.scrollTo({left: rail.scrollLeft + (r.left-rr.left) - (rr.width/2 - r.width/2), behavior:'smooth'});
      });
    },{rootMargin:'-45% 0px -50% 0px'});
    document.querySelectorAll('.pg-cat').forEach(function(s){ io.observe(s); });
  })();

  // (the masthead drop chip's scroll-to-row handler lived here; band removed 2026-08-09)

  tripRestore();
})();
</script>
'@

# ---- per-item PRICE-HISTORY POPUP (2026-07-11, Brad's ask): every board row with >=2 tracked weeks
# gets a "history" pill that opens a modal showing each store's price week by week. Data is embedded
# at build time from price-history.json (weekly staples have per_store history now; recipe-board items
# started accruing history the same day, so their pills light up automatically as weeks land).
$histBlock = ''
if ($histDoc) {
  $onPage = @{}
  foreach ($r in $doc.comparison) { $onPage[[string]$r.id] = $true }
  if ($riDoc) { foreach ($r in $riDoc.comparison) { $onPage[[string]$r.id] = $true } }
  function JStr2([string]$s){ return '"' + ($s -replace '\\','\\\\' -replace '"','\"') + '"' }
  $entries = @()
  foreach ($h in $histDoc.commodities) {
    $id = [string]$h.id
    if (-not $onPage.ContainsKey($id)) { continue }
    $hist = @($h.history | Sort-Object week_of)
    if ($hist.Count -lt 2) { continue }
    if ($hist.Count -gt 40) { $hist = @($hist | Select-Object -Last 40) }   # 21 daily + weekly tail (update-history compacts)
    $weeks = @($hist | ForEach-Object { ([string]$_.week_of).Substring(5) })
    $storeSet = [ordered]@{}
    foreach ($hw in $hist) { if ($hw.per_store) { foreach ($p in $hw.per_store.PSObject.Properties) { $storeSet[[string]$p.Name] = $true } } }
    if ($storeSet.Count -eq 0) { continue }
    $sParts = @()
    foreach ($sn in $storeSet.Keys) {
      $vals = @()
      foreach ($hw in $hist) {
        $v = $null
        if ($hw.per_store) { $pp = $hw.per_store.PSObject.Properties | Where-Object { $_.Name -eq $sn } | Select-Object -First 1; if ($pp) { $v = [double]$pp.Value } }
        if ($null -ne $v -and $v -gt 0) { $vals += ,([string]([math]::Round($v,4))) } else { $vals += ,'null' }
      }
      $sParts += ((JStr2 $sn) + ':[' + ($vals -join ',') + ']')
    }
    $t = 'null'
    # Only keep-listed commodities get a "Full history ->" link out to a standalone page. Everything
    # else keeps its history INLINE in this same modal (the per-store chart above is strictly richer
    # than the trend page ever was). See lib\trend-keep.ps1 for why the old >=3-weeks rule was wrong.
    if ((Test-TrendKeep $id) -and $h.src -ne 'recipe') { $t = JStr2 ($id + '-price-omaha') }
    $entries += ((JStr2 $id) + ':{"l":' + (JStr2 ([string]$h.label)) + ',"u":' + (JStr2 ([string]$h.unit)) + ',"t":' + $t + ',"w":[' + ((@($weeks | ForEach-Object { JStr2 $_ })) -join ',') + '],"s":{' + ($sParts -join ',') + '}}')
  }
  if ($entries.Count -gt 0) {
    $histJson = '{' + ($entries -join ',') + '}'
    $histBlock = @'
<style>
.pg-hist{border:1px solid #d5dbe4;background:#fff;color:#68748a;border-radius:999px;padding:2px 10px;font-size:.62em;font-weight:800;letter-spacing:.05em;text-transform:uppercase;cursor:pointer;font-family:inherit;margin-left:0;vertical-align:2px;white-space:nowrap;flex:0 0 auto;line-height:1.6}
.pg-hist:hover{border-color:#E2A43C;color:#8a6d1f}
.pg-hx-ov{position:fixed;inset:0;background:rgba(22,38,63,.55);z-index:9999;display:flex;align-items:center;justify-content:center;padding:16px}
.pg-hx{background:#fff;border-radius:16px;max-width:640px;width:100%;max-height:85vh;overflow:auto;padding:22px 22px 18px;box-shadow:0 24px 64px rgba(0,0,0,.3)}
.pg-hx-top{display:flex;justify-content:space-between;align-items:baseline;gap:12px;margin-bottom:4px}
.pg-hx h3{margin:0;font-size:1.25em;color:#16263F}
.pg-hx-x{border:none;background:#f1f4f8;color:#68748a;border-radius:8px;width:30px;height:30px;font-size:1.05em;font-weight:800;cursor:pointer;line-height:1;flex:0 0 auto}
.pg-hx-x:hover{background:#fbeceb;color:#b23b2e}
.pg-hx-sub{font-size:.82em;color:#8a94a6;margin:0 0 12px}
.tcc-none{font-size:.9em;color:#8a94a6;text-align:center;padding:2.2em 0}
.tcc-leg{display:flex;flex-wrap:wrap;gap:8px;margin-top:10px}
.tcc-chip{display:inline-flex;align-items:center;gap:7px;border:1px solid #e2e8f0;background:#fff;border-radius:999px;padding:5px 12px;font-size:.8em;color:#3a4658;font-weight:700;cursor:pointer;font-family:inherit;white-space:nowrap}
.tcc-chip i{width:16px;height:3px;border-radius:2px;display:inline-block}
.tcc-chip.is-off{opacity:.4}
.tcc-chip.is-off i{background:#c3cad6!important}
.tcc-chip:hover{border-color:#E2A43C}
.pg-alertp{border:1px solid #ecd9ae;background:#fdf8ec;color:#8a6d1f;border-radius:999px;padding:2px 10px;font-size:.62em;font-weight:800;letter-spacing:.05em;text-transform:uppercase;cursor:pointer;font-family:inherit;margin-left:0;vertical-align:2px;white-space:nowrap;flex:0 0 auto;line-height:1.6}
.pg-brandp{border:1px solid #cfe4d6;background:#eef7f1;color:#0f6b45;border-radius:999px;padding:2px 10px;font-size:.62em;font-weight:800;letter-spacing:.05em;text-transform:uppercase;cursor:pointer;font-family:inherit;vertical-align:2px;white-space:nowrap;flex:0 0 auto;line-height:1.6}
.pg-brandp:hover{border-color:#0f7a4e;color:#0c5c3b}
.pg-bt-wrap{overflow-x:auto;margin-top:6px}
.pg-bt{border-collapse:collapse;width:100%;font-size:.86em}
.pg-bt th{text-align:right;font-size:.8em;font-weight:700;color:#68748a;padding:5px 8px;white-space:nowrap;border-bottom:1px solid #e2e8f0}
.pg-bt th:first-child{text-align:left}
.pg-bt td{text-align:right;padding:5px 8px;border-top:1px solid #eef1f5;white-space:nowrap;font-variant-numeric:tabular-nums;color:#16263f;font-weight:600}
.pg-bt td:first-child{text-align:left}
.pg-bt-store td:first-child{font-weight:800;color:#b07c1e}
.pg-bt-store td:first-child::after{content:"STORE";font-size:.62em;letter-spacing:.04em;background:#fbf1dc;color:#8a6d1f;border-radius:4px;padding:1px 5px;margin-left:6px}
.pg-bt-cheap{background:#e5f1eb;color:#0f7a4e;font-weight:800;border-radius:5px}
.pg-bt-none{color:#c0c8d2;font-weight:400}
.pg-alertp:hover{border-color:#E2A43C;color:#16263F}
.pg-al-form{margin-top:14px}
.pg-al-form input[type=email]{width:100%;padding:.7em .9em;font-size:1em;border:1.5px solid #e2e8f0;border-radius:10px;font-family:inherit;color:#16263F;box-sizing:border-box}
.pg-al-form input[type=email]:focus{outline:none;border-color:#E2A43C;box-shadow:0 0 0 3px rgba(226,164,60,.2)}
.pg-al-week{display:flex;gap:.6em;align-items:flex-start;font-size:.85em;color:#3a4658;margin:10px 0 12px;line-height:1.45}
.pg-al-week input{margin-top:.2em;accent-color:#e2a43c}
.pg-al-btn{background:#E2A43C;color:#16263F;border:none;border-radius:10px;padding:.8em 1.6em;font-size:1em;font-weight:800;cursor:pointer;font-family:inherit;width:100%}
.pg-al-btn:disabled{opacity:.6;cursor:default}
.pg-al-msg{font-size:.9em;margin:10px 0 0;min-height:1.3em}
.pg-al-msg.ok{color:#1f7a4d;font-weight:700}
.pg-al-msg.err{color:#b23b2e;font-weight:600}
.pg-al-fine{font-size:.75em;color:#8a94a6;margin:10px 0 0;line-height:1.5}
.pg-al-hp{position:absolute;left:-9999px;opacity:0;height:0;overflow:hidden}
.pg-gate{text-align:center;padding:2px 4px 2px}
.pg-gate-ic{font-size:2.1em;line-height:1;margin:0 0 6px}
.pg-gate h3{font-size:1.28em;color:#16263F;margin:0 0 8px}
.pg-gate-body{font-size:.92em;color:#3a4658;line-height:1.55;margin:0 auto 14px;max-width:34em}
.pg-gate-price{font-size:.86em;font-weight:600;color:#5a6577;margin:9px 0 0}
.pg-gate-join{display:block;width:100%;background:#E2A43C;color:#16263F;border:none;border-radius:10px;padding:.85em 1.6em;font-size:1.02em;font-weight:800;cursor:pointer;font-family:inherit;text-decoration:none;text-align:center;box-sizing:border-box}
.pg-gate-join:hover{background:#d9992f}
.pg-gate-year{margin-top:11px;font-size:.9em;font-weight:700;color:#1E3A5F;background:none;border:none;cursor:pointer;font-family:inherit;text-decoration:underline;text-underline-offset:2px;padding:2px}
.pg-gate-fine{font-size:.75em;color:#8a94a6;margin:12px 0 0;line-height:1.5}
.pg-gate-later{margin-top:9px;font-size:.85em;color:#8a94a6;background:none;border:none;cursor:pointer;font-family:inherit;padding:4px}
.pg-gate-later:hover{color:#16263F}
.pg-hx-foot{display:flex;justify-content:space-between;align-items:center;gap:10px;margin-top:12px;flex-wrap:wrap}
.pg-hx-note{font-size:.75em;color:#8a94a6}
.pg-hx-trend{font-size:.85em;font-weight:700;color:#8a6d1f;text-decoration:none}
.pg-hx-trend:hover{color:#16263F}
</style>
<script>
(function(){
  // Price history is FETCHED LAZILY. It used to be a 252 KB inline blob: shipped to EVERY visitor (on
  // mobile) just to support an occasional "history" click, and it pushed the post payload past Ghost's
  // upsert timeout (503 = board could not publish at all). TCH_IDS is a tiny id index so the pills still
  // render at load; the real data loads from the feed Worker on first open and is cached for the session.
  var TCH = null;
  var TCH_IDS = __TCH_IDS__;
  var TCH_URL = '__TCH_URL__';
  var _tchP = null;
  function loadTCH(){
    if (TCH) return Promise.resolve(TCH);
    if (!_tchP) {
      _tchP = fetch(TCH_URL).then(function(r){ return r.ok ? r.json() : null; })
        .then(function(j){ TCH = j || {}; return TCH; })
        .catch(function(){ _tchP = null; return null; });
    }
    return _tchP;
  }
  // ONE fetch of price-history.json for the whole page. The sparklines in the expanded panels are drawn
  // from THIS loader, not a second copy of the same request: the file is lazy on purpose (zero initial
  // bytes) and two independent fetchers would double the cost of the first row anyone opens.
  window.__tcHist = { load: loadTCH, get: function(id){ return TCH ? TCH[id] : null; }, has: function(id){ return !!TCH_IDS[id]; } };
  var TCB = (__TCB_JSON__).commodities || {};
  function fmt(v){ if (v === null || v === undefined) return ''; return v < 1 ? '$' + v.toFixed(3) : '$' + v.toFixed(2); }
  function esc(s){ return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
  // add pills to every row: "history" (when we have data) + "alerts" (every tracked item)
  var rows = document.querySelectorAll('.pg-row[data-id]');
  for (var i = 0; i < rows.length; i++){
    var id = rows[i].getAttribute('data-id');
    var head = rows[i].querySelector('.pg-rh-bot');
    if (!head) continue;
    if (TCH_IDS[id]){
      var b = document.createElement('button');
      b.type = 'button'; b.className = 'pg-hist'; b.setAttribute('data-hid', id); b.textContent = 'history';
      b.title = "Every store's price for this item, week by week";
      head.appendChild(b);
    }
    var nameEl = rows[i].querySelector('.pg-name');
    var a = document.createElement('button');
    a.type = 'button'; a.className = 'pg-alertp'; a.setAttribute('data-aid', id);
    a.setAttribute('data-aname', nameEl ? nameEl.textContent : id);
    a.textContent = 'alerts';
    a.title = 'Get an email when this hits a low price';
    head.appendChild(a);
    if (TCB[id]){
      var br = document.createElement('button');
      br.type = 'button'; br.className = 'pg-brandp'; br.setAttribute('data-bid', id);
      br.textContent = 'brands'; br.title = 'Compare name brands vs the store brand across stores';
      head.appendChild(br);
    }
  }
  var ov = null;
  function close(){ if (ov && ov.parentNode) ov.parentNode.removeChild(ov); ov = null; }
  __TCCHART__
  function openBrands(id){
    var d = TCB[id]; if (!d) return; close();
    var sts = d.stores || [];
    var h = '<div class="pg-hx" style="max-width:660px"><div class="pg-hx-top"><h3>Brands: ' + esc(d.label) + '</h3><button type="button" class="pg-hx-x" aria-label="Close">&times;</button></div>';
    h += '<p class="pg-hx-sub">Price per ' + esc(d.unit) + ', cheapest brand first. The <b>store brand</b> is gold; the cheapest store for each brand is green. A dash means that store&rsquo;s search did not surface that brand.</p>';
    h += '<div class="pg-bt-wrap"><table class="pg-bt"><thead><tr><th>Brand</th>';
    for (var s = 0; s < sts.length; s++){ h += '<th>' + esc(sts[s]) + '</th>'; }
    h += '</tr></thead><tbody>';
    for (var r = 0; r < d.brands.length; r++){ var bd = d.brands[r];
      h += '<tr' + (bd.store ? ' class="pg-bt-store"' : '') + '><td>' + esc(bd.label) + '</td>';
      for (var s2 = 0; s2 < sts.length; s2++){ var st = sts[s2]; var v = bd.prices[st];
        if (v === undefined || v === null){ h += '<td class="pg-bt-none">&mdash;</td>'; }
        else { var cheap = (st === bd.cheapest && sts.length > 1); h += '<td class="pg-bt-p' + (cheap ? ' pg-bt-cheap' : '') + '">$' + (v < 1 ? v.toFixed(3) : v.toFixed(2)) + '</td>'; }
      }
      h += '</tr>';
    }
    h += '</tbody></table></div>';
    h += '<p class="pg-hx-note" style="margin-top:11px">Real Omaha shelf prices captured this week. Sam&rsquo;s Club needs a membership. Aldi and Fareway are not shown here, since neither posts everyday brand prices online.</p></div>';
    ov = document.createElement('div'); ov.className = 'pg-hx-ov'; ov.innerHTML = h;
    document.body.appendChild(ov);
    ov.addEventListener('click', function(e){ if (e.target === ov || e.target.closest('.pg-hx-x')) close(); });
  }
  function open(id){
    if (!TCH_IDS[id]) return;
    loadTCH().then(function(){ if (TCH && TCH[id]) openNow(id); });
  }
  function openNow(id){
    var d = TCH[id]; if (!d) return;
    close();
    var h = '<div class="pg-hx"><div class="pg-hx-top"><h3>' + esc(d.l) + '</h3><button type="button" class="pg-hx-x" aria-label="Close">&times;</button></div>';
    h += '<p class="pg-hx-sub">Price per ' + esc(d.u) + ' at each store over time. Tap a dot for the exact price; tap a store below to hide or show its line.</p>';
    h += '<div class="pg-hx-chart"></div>';
    h += '<div class="pg-hx-foot"><span class="pg-hx-note">Daily checks for the last three weeks, weekly before that. History deepens as we track.</span>';
    h += '<span><button type="button" class="pg-alertp" data-aid="' + esc(id) + '" data-aname="' + esc(d.l) + '" style="margin-left:0">Get alerted on lows</button>' + (d.t ? ' <a class="pg-hx-trend" href="/' + d.t + '/?ref=board-history">Full history &rarr;</a>' : '') + '</span>';
    h += '</div></div>';
    ov = document.createElement('div');
    ov.className = 'pg-hx-ov';
    ov.innerHTML = h;
    document.body.appendChild(ov);
    tcChart(ov.querySelector('.pg-hx-chart'), d);
    ov.addEventListener('click', function(e){ if (e.target === ov || e.target.closest('.pg-hx-x')) close(); });
  }
  var ALERT_URL = 'https://feed.thriftycrew.com/alert';
  // Price alerts are a PAID-member perk. Non-paid clicks get the join interstitial (paid tier only, no free option).
  var PAID_TIER = '6a43628ae02523000897528f';
  var PAID_MO = '#/portal/signup/' + PAID_TIER + '/monthly';
  var PAID_YR = '#/portal/signup/' + PAID_TIER + '/yearly';
  var TC_PAID = null, TC_MEMBER = null;
  function tcIsPaid(cb){
    // fast path: the site-wide member block stamps html.tc-paid for paid/comped members
    if (document.documentElement.classList.contains('tc-paid')) { cb(true); return; }
    if (TC_PAID !== null) { cb(TC_PAID); return; }
    fetch('/members/api/member/', { credentials: 'include' })
      .then(function(r){ return r.ok ? r.json() : null; })
      .then(function(m){ TC_MEMBER = m; var st = m ? (m.status || (m.paid ? 'paid' : 'free')) : null; TC_PAID = (st === 'paid' || st === 'comped'); cb(TC_PAID); })
      .catch(function(){ TC_PAID = false; cb(false); });
  }
  function goPortal(hash){ close(); try { window.location.hash = hash; } catch(e){ window.location.href = '/' + hash; } }
  function openAlert(id, name){ tcIsPaid(function(paid){ if (paid) openAlertForm(id, name); else openAlertGate(name); }); }
  function openAlertGate(name){
    close();
    var h = '<div class="pg-hx" style="max-width:440px"><div class="pg-hx-top" style="justify-content:flex-end;margin-bottom:0"><button type="button" class="pg-hx-x" aria-label="Close">&times;</button></div>';
    h += '<div class="pg-gate">';
    h += '<div class="pg-gate-ic" aria-hidden="true">&#128276;</div>';
    h += '<h3>Price alerts are a member perk</h3>';
    h += '<p class="pg-gate-body">Get one short email the moment ' + esc(name.toLowerCase()) + ' hits the lowest price we have tracked in Omaha. Alerts come with your Thrifty Crew membership, along with every tool, all the recipes, and the full price history.</p>';
    h += '<a href="' + PAID_MO + '" class="pg-gate-join" id="pg-gate-mo">Join the Crew &rarr;</a>';
    h += '<p class="pg-gate-price">$1 a month, or $10 for the whole year.</p>';
    h += '<div><button type="button" class="pg-gate-year" id="pg-gate-yr">Pay for the year instead</button></div>';
    h += '<p class="pg-gate-fine">Not a trial, not an intro rate. Cancel anytime in two clicks.</p>';
    h += '<div><button type="button" class="pg-gate-later">Maybe later</button></div>';
    h += '</div></div>';
    ov = document.createElement('div');
    ov.className = 'pg-hx-ov';
    ov.innerHTML = h;
    document.body.appendChild(ov);
    ov.addEventListener('click', function(e){
      if (e.target.closest('#pg-gate-mo')) { e.preventDefault(); goPortal(PAID_MO); return; }
      if (e.target.closest('#pg-gate-yr')) { goPortal(PAID_YR); return; }
      if (e.target === ov || e.target.closest('.pg-hx-x') || e.target.closest('.pg-gate-later')) { close(); return; }
    });
  }
  function openAlertForm(id, name){
    close();
    var h = '<div class="pg-hx" style="max-width:480px"><div class="pg-hx-top"><h3>Price alerts: ' + esc(name) + '</h3><button type="button" class="pg-hx-x" aria-label="Close">&times;</button></div>';
    h += '<p class="pg-hx-sub">One short email when ' + esc(name.toLowerCase()) + ' hits the lowest price we have tracked in Omaha. No spam, no daily digests, just the good news.</p>';
    h += '<div class="pg-al-form"><input type="email" id="pg-al-email" placeholder="you@email.com" maxlength="200" autocomplete="email">';
    h += '<input type="text" class="pg-al-hp" id="pg-al-web" tabindex="-1" autocomplete="off" aria-hidden="true">';
    h += '<label class="pg-al-week"><input type="checkbox" id="pg-al-week" checked> Also send me the weekly cheapest-groceries roundup (you can turn either off anytime)</label>';
    h += '<button type="button" class="pg-al-btn" id="pg-al-go" data-aid="' + esc(id) + '">Alert me on low prices</button>';
    h += '<p class="pg-al-msg" id="pg-al-msg"></p>';
    h += '<p class="pg-al-fine">Included with your membership. Every email has an unsubscribe link.</p>';
    h += '</div></div>';
    ov = document.createElement('div');
    ov.className = 'pg-hx-ov';
    ov.innerHTML = h;
    document.body.appendChild(ov);
    ov.addEventListener('click', function(e){ if (e.target === ov || e.target.closest('.pg-hx-x')) close(); });
    setTimeout(function(){ var inp = document.getElementById('pg-al-email'); if (inp){ if (TC_MEMBER && TC_MEMBER.email) inp.value = TC_MEMBER.email; inp.focus(); } }, 50);
  }
  function submitAlert(btn){
    var id = btn.getAttribute('data-aid');
    var email = (document.getElementById('pg-al-email') || {value:''}).value.trim();
    var weekly = !!(document.getElementById('pg-al-week') || {}).checked;
    var hp = (document.getElementById('pg-al-web') || {value:''}).value;
    var msg = document.getElementById('pg-al-msg');
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)){ msg.className = 'pg-al-msg err'; msg.textContent = 'That email does not look right.'; return; }
    btn.disabled = true; msg.className = 'pg-al-msg'; msg.textContent = 'Signing you up...';
    fetch(ALERT_URL, { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({ email: email, item: id, weekly: weekly, website: hp }) })
      .then(function(r){ return r.json(); })
      .then(function(j){
        if (j && j.ok){ msg.className = 'pg-al-msg ok'; msg.textContent = 'Done. We will email you when it hits a low.'; btn.textContent = 'You are on the list'; }
        else { msg.className = 'pg-al-msg err'; msg.textContent = (j && j.error) || 'Could not sign you up right now.'; btn.disabled = false; }
      })
      .catch(function(){ msg.className = 'pg-al-msg err'; msg.textContent = 'Could not reach the sign-up service. Try again in a minute.'; btn.disabled = false; });
  }
  document.addEventListener('click', function(e){
    var b = e.target.closest('.pg-hist'); if (b){ open(b.getAttribute('data-hid')); return; }
    var brb = e.target.closest('.pg-brandp'); if (brb){ openBrands(brb.getAttribute('data-bid')); return; }
    var g = e.target.closest('#pg-al-go'); if (g){ submitAlert(g); return; }
    var a = e.target.closest('.pg-alertp'); if (a){ openAlert(a.getAttribute('data-aid'), a.getAttribute('data-aname') || a.getAttribute('data-aid')); return; }
  });
  document.addEventListener('keydown', function(e){ if (e.key === 'Escape') close(); });
})();
</script>
'@
    $tcChartJs = [IO.File]::ReadAllText((Join-Path $root 'tc-chart.js'), [Text.Encoding]::UTF8)
    $tcbFile = Join-Path $root 'out\brands\brands-board.json'
    $tcbJson = if (Test-Path $tcbFile) { (Get-Content $tcbFile -Raw).Trim() } else { '{"commodities":{}}' }
    # The history data is served from the feed Worker instead of inlined. Inlining it cost ~252 KB in EVERY
    # board post + every mobile page load, and pushed the Ghost upsert past its timeout (503 = unpublishable).
    # We still inline a tiny id index (TCH_IDS) so the "history" pills render at load with no fetch.
    $histOut = Join-Path (Split-Path $root -Parent) 'public\price-history.json'   # C:\Codex\ThriftyCrew\public\
    $histDir = Split-Path $histOut -Parent
    if (-not (Test-Path $histDir)) { New-Item -ItemType Directory -Force -Path $histDir | Out-Null }
    # BOM-LESS (L7, 2026-08-01). Set-Content -Encoding UTF8 emits a UTF-8 BOM in PS 5.1. Browsers strip it
# per spec so the live page was never broken - but PS 5.1's OWN ConvertFrom-Json chokes on it, which is
# how a verification pass reported this feed "malformed" when it was fine. Our own tooling has to be able
# to read what we publish.
[IO.File]::WriteAllText($histOut, $histJson, (New-Object Text.UTF8Encoding($false)))
    $idIndex = '{' + ((@($entries | ForEach-Object { ($_ -split ':\{')[0] + ':1' })) -join ',') + '}'
    Write-Output ("history: {0} items -> public\price-history.json ({1} KB, lazily fetched); inline index {2} KB" -f $entries.Count, [math]::Round($histJson.Length/1KB,0), [math]::Round($idIndex.Length/1KB,1))
    # content-hash cache-bust (same reason as board.json: the feed is cached 30 min, the post can be newer)
    $hsha = New-Object System.Security.Cryptography.SHA1Managed
    $hhash = ([BitConverter]::ToString($hsha.ComputeHash([Text.Encoding]::UTF8.GetBytes($histJson))) -replace '-','').Substring(0,10).ToLower()
    $histUrl = 'https://feed.thriftycrew.com/price-history.json?v=' + $hhash
    $histBlock = $histBlock.Replace('__TCH_IDS__', $idIndex).Replace('__TCH_URL__', $histUrl).Replace('__TCB_JSON__', $tcbJson).Replace('__TCCHART__', $tcChartJs)
  }
}

# ---- store chips -> public/board.json (served by the feed Worker), NOT inside the post ----
# See the lazy-chip note where $boardChips is filled. The post keeps every row's server-rendered answer; the
# per-store breakdown is fetched and injected client-side. This is what takes the post back under Ghost's
# upsert-processing ceiling so the board can publish at all.
$boardOut = Join-Path (Split-Path $root -Parent) 'public\board.json'
$boardDir = Split-Path $boardOut -Parent
if (-not (Test-Path $boardDir)) { New-Item -ItemType Directory -Force -Path $boardDir | Out-Null }
# ConvertTo-Json (not hand-rolled escaping): the chip html is full of quotes/apostrophes/entities and one
# mis-escaped row would break the whole feed parse and silently empty every store breakdown.
$boardJson = ($boardChips | ConvertTo-Json -Depth 3 -Compress)
  # BOM-LESS - see the note on price-history.json above.
  [IO.File]::WriteAllText($boardOut, $boardJson, (New-Object Text.UTF8Encoding($false)))
# CACHE-BUST WITH A CONTENT HASH. The feed is served with max-age=1800, so a freshly published post can fetch a
# 30-minute-old board.json - rows added since would find no key and never fill (seen live: 15 empty rows, and a
# store still showing its pre-fix chip count). The post and the feed MUST move together, so the URL changes
# whenever the content does.
$sha = New-Object System.Security.Cryptography.SHA1Managed
$bhash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($boardJson))) -replace '-','').Substring(0,10).ToLower()
$boardUrl = 'https://feed.thriftycrew.com/board.json?v=' + $bhash
$js = $js.Replace('__BOARD_URL__', $boardUrl)
$js = $js.Replace('__WEEK__', $week)
$js = $js.Replace('__STORE_HUES__', (($storeAccent | ConvertTo-Json -Compress)))
# THE DEMO BASKET, resolved at build time against the rows that actually rendered. A curated staples list
# is only a demo if every id in it is on the page; the build FAILS rather than shipping a "Try it" button
# that checks nine of fifteen boxes. Alternates cover the ordinary case where one staple drops out for a
# week; if even the alternates cannot reach the floor, that is a coverage problem worth stopping for.
$demoWant = @('milk','eggs','chicken-breast','ground-beef-8020','bread','butter','bananas','russet-potatoes','onions','rice','pasta','canned-black-beans','peanut-butter','flour','carrots')
$demoAlt  = @('apples','sugar','chicken-thighs','pasta-sauce','sweet-potatoes','brown-rice','chicken-broth','egg-noodles','kidney-beans','brown-sugar')
$demoIds = @()
foreach ($d in $demoWant) { if ($stapleRendered.ContainsKey($d)) { $demoIds += $d } }
foreach ($d in $demoAlt)  { if (@($demoIds).Count -ge 15) { break }; if ($stapleRendered.ContainsKey($d)) { $demoIds += $d } }
if (@($demoIds).Count -lt 15) {
  Write-Output ("DEMO BASKET COVERAGE: only " + @($demoIds).Count + " of 15 curated staples rendered a row. The 'Try it' basket would demo a partial list, so it is being DROPPED this build. Ids missing: " + ((@($demoWant) + @($demoAlt) | Where-Object { -not $stapleRendered.ContainsKey($_) }) -join ', '))
  $demoIds = @()
}
# hand-built, not ConvertTo-Json: PS 5.1 renders a one-element array as a bare scalar and an empty one as
# nothing at all, either of which would emit JS that does not parse (the ps51-json-array-traps class).
$js = $js.Replace('__DEMO_IDS__', ('[' + ((@($demoIds) | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']'))
if (-not @($demoIds).Count) { $body = $body -replace "<button type='button' class='pg-demo' id='pg-demo'>[^<]*</button>", '' }
Write-Output ("chips: {0} rows -> public\board.json ({1} KB, lazily injected); post keeps the per-row answer" -f $boardChips.Count, [math]::Round($boardJson.Length/1KB,0))

# ---- THE ALL-3 ASSERTION (Brad's rule, 2026-07-23): a tile that shows a price MUST carry a link. ----
# SeeLink now guarantees this by construction (exact link -> weekly-ad pill -> store-search fallback), but a
# construction guarantee without an assertion is one refactor away from silent regression - so scan the FINAL
# HTML: every pg-chip that contains a pg-price must contain an <a. Hard-fail the build (exit 2) on any
# violation; a build that fails here never reaches publish.
$finalHtml = ($css + $eliteCss + (Compress-TcAsset (Get-TcMotionJs)) + $body + $js + $histBlock)

# ---- THE DESIGN-SYSTEM SELF-CHECKS (elite layer: enforced by a grep in the builder, not by a comment) ----
# Two navy bands may never sit adjacent, navy never sits behind body prose, and gold never becomes a
# heading colour. These are cheap, they run on the FINAL html, and they hard-fail the build, because a
# rule that only lives in a design document is a rule that quietly stops being true.
$dsBad = @()
$dsBad += (Test-TcNavyAdjacency -Html $finalHtml)
$dsBad += (Test-TcGoldDiscipline -Html $finalHtml)
if (@($dsBad).Count) {
  Write-Output ("DESIGN-SYSTEM VIOLATION: " + ($dsBad -join ' | ') + " - NOT writing the page.")
  exit 2
}
# every placeholder the JS carries must have been substituted; an unreplaced __TOKEN__ ships a page whose
# script does not parse, and the board would look fine in the HTML right up until nothing worked
foreach ($tok in @('__BOARD_URL__','__WEEK__','__STORE_HUES__','__DEMO_IDS__','__TCH_IDS__','__TCH_URL__')) {
  if ($finalHtml -match [regex]::Escape($tok)) { Write-Output ("UNSUBSTITUTED PLACEHOLDER $tok reached the final page - the script would not parse. NOT writing."); exit 2 }
}
# scan BOTH artifacts: the page shell AND every chip row in the board.json feed (that is where the priced
# chips actually live - they are injected client-side; asserting only the page shell guards almost nothing)
$bare = 0; $searchN = 0; $pricedN = 0
$scanTargets = @($finalHtml) + @($boardChips.Values)
foreach ($target in $scanTargets) {
  $parts = [regex]::Split([string]$target, "<div class='pg-chip")
  for ($i = 1; $i -lt $parts.Count; $i++) {   # parts[0] precedes the first chip
    # a chip contains no nested divs, so its own markup ends at the FIRST </div> - cutting there stops a
    # later element's <a from masking a bare chip in the same split segment
    $seg = $parts[$i]
    $end = $seg.IndexOf('</div>')
    if ($end -ge 0) { $seg = $seg.Substring(0, $end) }
    if ($seg -match 'pg-price') {
      $pricedN++
      if ($seg -match 'pg-see-search') { $searchN++ }
      if ($seg -notmatch '<a ') { $bare++ }
    }
  }
}
if ($bare -gt 0) {
  Write-Output ("ALL-3 VIOLATION: $bare priced chip(s) rendered without any link - the SeeLink fallback chain is broken. NOT writing the page.")
  exit 2
}
$finalHtml | Set-Content $Out -Encoding UTF8
Write-Output ("all-3 rule: $pricedN priced chips, 0 bare ($searchN on store-search fallback links)")
Write-Output ("deals page -> " + $Out + "  (" + $totalCommodities + " commodities, " + $totalPrices + " prices, history popup on " + $(if ($entries) { $entries.Count } else { 0 }) + " items)")



