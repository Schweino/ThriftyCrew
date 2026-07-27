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
$weeksOnRecord = 0
# stock-up set: commodities that keep (freezer/pantry) - a record price on one of these earns a "Stock up" tag
$stockup = @{}
$suFile = Join-Path $root 'stockup-items.json'
if (Test-Path $suFile) { try { $suDoc = Get-Content $suFile -Raw | ConvertFrom-Json; foreach ($p in $suDoc.items.PSObject.Properties) { $stockup[[string]$p.Name] = [string]$p.Value } } catch {} }
$histFile = Join-Path $root 'price-history.json'
if (Test-Path $histFile) {
  try {
    $histDoc = Get-Content $histFile -Raw | ConvertFrom-Json
    $weeksOnRecord = [int]$histDoc.weeks_on_record
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
        $recBadge[[string]$r.id] = @{ cls='pg-rec-low'; label='Record low'; rank=0; su=$suNote; title=("Cheapest we have seen in " + $wkN + " weeks of tracking. Previous best " + ('${0:N2}' -f $priorMin) + "/" + $r.unit + ".") }
      } elseif ($P -eq $priorMin) {
        $recBadge[[string]$r.id] = @{ cls='pg-rec-tie'; label='Ties record'; rank=1; su=$suNote; title=("Matches the lowest price in " + $wkN + " weeks of tracking.") }
      } else {
        $weeksAbove = 0; $since = $null
        foreach ($e in ($prior | Sort-Object week_of -Descending)) { if ([double]$e.cheapest_price -gt $P) { $weeksAbove++ } else { $since = $e.week_of; break } }
        if ($weeksAbove -ge 2) { $recBadge[[string]$r.id] = @{ cls='pg-rec-dip'; label=('Lowest in ' + $weeksAbove + ' wks'); rank=2; su=$suNote; title=("Cheapest since " + $since + ".") } }
        elseif ($P -le ($priorMin * 1.05)) {
          # Buy-or-Wait layer: within 5% of the tracked low = a good week to buy
          $verdict[[string]$r.id] = @{ cls='pg-verd-buy'; label='Good price'; title=("Within 5% of the lowest we have tracked (" + ('${0:N2}' -f $priorMin) + "/" + $r.unit + "). A fine week to buy.") }
        }
        elseif ($P -gt ($priorMin * 1.15)) {
          # >15% above the tracked low = it usually comes back down
          $verdict[[string]$r.id] = @{ cls='pg-verd-wait'; label='Usually cheaper'; title=("Lowest we have tracked: " + ('${0:N2}' -f $priorMin) + "/" + $r.unit + " at " + $priorMinStore + ". If it can wait, it usually comes back down.") }
        }
      }
    }
  } catch { $recBadge = @{} }
}

# optional: recipe-ingredient board (the 100 meal-prep recipes' ingredients, all 6 stores). Additive; renders below the weekly staples when present.
$riDoc = $null; $riCats = @()
$riFile = Join-Path $OutDir 'recipe-board.json'
if (Test-Path $riFile) { $riDoc = Get-Content $riFile -Raw | ConvertFrom-Json; $riCats = @($riDoc.comparison | ForEach-Object { [string]$_.category } | Select-Object -Unique); $ovrN += (Apply-Overrides $riDoc.comparison) }

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
  'Family Fare' = 'https://www.shopfamilyfare.com/search?search_term={q}'
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
          # brand swap: "Fresh Peaches" âŠ‚ "Tree Ripened Yellow Flesh Peaches, Small" -> show (same commodity,
          # less flowery), but "Kroger Thick Cut Bacon" âŠ„ "Oscar Mayer Bacon" -> still hidden (different brand,
          # even at a plausible price). Band is REQUIRED here.
          if (-not $ident -and ($null -ne $lpu) -and ($lpu -ge $boardPU * 0.85) -and ($lpu -le $boardPU * 3.0) -and (CommodityIdent $id ([string]$lnk.name)) -and (NameMatch ([string]$lnk.name) $boardItem)) { $ident = $true }
          if (-not $ident) { $ok = $false }
          elseif (($null -ne $lpu) -and ($lpu -lt $boardPU * 0.85 -or $lpu -gt $boardPU * 3.0)) { $ok = $false }
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

# store scoreboard: how many commodities each store is the outright cheapest on (the summary a shopper wants first)
$storeOrder = @('Hy-Vee','Aldi','Family Fare','Fareway',"Baker's","Sam's Club",'Walmart')
$wins = [ordered]@{}; foreach ($s in $storeOrder) { $wins[$s] = 0 }
foreach ($r in $doc.comparison) { $cs = [string]$r.cheapest_store; if ($wins.Contains($cs)) { $wins[$cs]++ } }
if ($riDoc) { foreach ($r in $riDoc.comparison) { $cs = [string]$r.cheapest_store; if ($wins.Contains($cs)) { $wins[$cs]++ } } }

# short store display names + stable column color accents
$shortName = @{ 'Hy-Vee'='Hy-Vee'; 'Aldi'='Aldi'; 'Family Fare'='Family Fare'; 'Fareway'='Fareway'; "Baker's"="Baker's"; "Sam's Club"="Sam's Club"; 'Walmart'='Walmart' }

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
[void]$sb.Append("<p class='pg-note'>Lowest verified price at each store, sale or everyday, checked against the store's own ad or site. Sam's Club prices need a membership.</p>")
# THE RETURN RHYTHM: ads flip Wednesdays, so today's sale prices have a real deadline. Saying so gives every
# visit urgency and every visitor a reason to come back on a schedule - the habit is the product.
[void]$sb.Append("<p class='pg-cycle'>Sale prices end when the new ads drop <strong>Wednesday morning</strong>. This board is re-checked every morning by 7am.</p>")
# THE TRUST LINE (Brad's voice, approved 2026-07-17). Reddit's first instinct on a polished price site is
# "who profits from this?" - this answers it before the ask below. Do not edit without Brad.
[void]$sb.Append("<p class='pg-trust'>I'm Brad. I live here in Omaha, and I check these prices every morning before most people are awake. No store pays to be on this board, there are no affiliate links, and no one can buy the word 'cheapest.' If a store wins, it's because their shelf price won.</p>")
# THE ASK, where the value is. 1,182 visitors in 30 days reached this page and the first signup control sat
# 70% down, below 378 rows - one converted. This is the product-shaped ask: the thing they are already using,
# delivered to them. Ghost Portal handles the signup (data-portal opens the free-tier modal).
[void]$sb.Append("<div class='pg-capture'><div class='pg-capture-txt'><strong>Get this board every Friday, free.</strong> The updated prices and biggest drops, in your inbox before you shop the weekend.</div><a class='pg-capture-btn' href='#/portal/signup/free' data-portal='signup/free'>Email me the board &rarr;</a></div>")
[void]$sb.Append("<p class='pg-suggest'><a href='/suggest-an-item/'>Suggest an item for us to start tracking! &rarr;</a></p></header>")

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
$trackedCount = @($doc.comparison).Count
[void]$sb.Append("<div class='pg-board'><span class='pg-board-h'>Cheapest-store scoreboard &middot; items each store wins this week</span><div class='pg-board-sub'><b>" + $trackedCount + " items</b> tracked across " + $storeOrder.Count + " Omaha stores, updated daily</div><div class='pg-board-row'>")
foreach ($s in $storeOrder) {
  $n = $wins[$s]
  $cls = 'pg-score'; if ($n -eq $maxWins -and $n -gt 0) { $cls += ' is-lead' }
  [void]$sb.Append("<div class='" + $cls + "' data-store=`"" + (HtmlEnc $s) + "`"><span class='pg-score-n'>" + $n + "</span><span class='pg-score-s'>" + (HtmlEnc $shortName[$s]) + "</span></div>")
}
[void]$sb.Append("</div></div>")
# ---- price-records band: this week's record lows / ties / dips, from the badge pass up top ----
if ($recBadge.Count -gt 0) {
  $recList = @()
  foreach ($k in $recBadge.Keys) { $rr = $byId[$k]; if ($rr) { $recList += ,@{ b = $recBadge[$k]; r = $rr } } }
  $recList = @($recList | Sort-Object { $_.b.rank }, { [double]$_.r.cheapest_price })
  $shown = @($recList | Select-Object -First 8)
  [void]$sb.Append("<div class='pg-recband'><span class='pg-recband-h'>Price records this week</span><div class='pg-recband-row'>")
  foreach ($e in $shown) {
    $rr = $e.r; $bb = $e.b
    $suTag = if ($bb.su) { " &middot; stock up" } else { "" }
    [void]$sb.Append("<div class='pg-recchip' title=`"" + (HtmlEnc $bb.title) + "`"><b>" + (Fmt-Price ([double]$rr.cheapest_price) ([string]$rr.unit)) + "</b><span>" + (HtmlEnc $rr.commodity) + "</span><em>" + $bb.label + " &middot; " + (HtmlEnc $shortName[[string]$rr.cheapest_store]) + $suTag + "</em></div>")
  }
  [void]$sb.Append("</div>")
  $more = $recList.Count - $shown.Count
  $tail = if ($more -gt 0) { "+" + $more + " more marked in the list below. " } else { "" }
  [void]$sb.Append("<span class='pg-recband-sub'>" + $tail + "From " + $weeksOnRecord + " weeks of Omaha price tracking, and counting.</span></div>")
}
# ---- trip planner home: ALWAYS visible right under the scoreboard so shoppers know it exists ----
[void]$sb.Append("<div class='pg-tripbox' id='pg-tripbox'><h3>Plan your shopping trip</h3>")
[void]$sb.Append("<p class='pg-tripbox-sub' id='pg-tripbox-sub'>Tick the box next to each item you want to buy, then come back here. Tell us how many stores you are willing to visit and we will split your list for the cheapest trip.</p>")
[void]$sb.Append("<div id='pg-tripbox-body' hidden><p class='pg-tripbox-n'><b id='pg-tripbox-count'>0 items</b> selected. How many stores are you willing to visit?</p><div class='pg-plan-kbtns' id='pg-plan-kbtns'></div><div class='pg-plan-out' id='pg-plan-out'></div><p class='pg-plan-note'>Based on this week's verified per-unit prices. Register totals vary by package size.</p></div></div>")
# hide-Sam's toggle: recomputes the cheapest flags + scoreboard for shoppers without a membership
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
function SummaryHtml($best, [string]$unit) {
  if (-not $best) { return '' }
  $tag = if ([string]$best.type -eq 'sale') { " <span class='pg-tag pg-tag-sale'>sale</span>" } else { '' }
  return "<span class='pg-sum'><span class='pg-sum-p'>" + (Fmt-Price ([double]$best.per_unit) $unit) + "</span><span class='pg-sum-s'>" + (HtmlEnc $shortName[[string]$best.store]) + "</span>" + $tag + "</span>"
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
foreach ($c in $cats) {
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
    [void]$sb.Append("<div class='pg-rowhead'><div class='pg-rh-top'><label class='pg-pickl' title='Add to my shopping list'><input type='checkbox' class='pg-pick' aria-label='Add to my shopping list'></label><span class='pg-name'>" + (HtmlEnc $r.commodity) + "</span><span class='pg-chev' aria-hidden='true'></span>" + $sumHtml + "</div><div class='pg-rh-bot'><span class='pg-unit'>" + (UnitLabel $unit) + "</span>" + $rbHtml + "</div></div>")
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
      [void]$cb.Append("<div class='" + $cls + "' data-store=`"" + (HtmlEnc ([string]$s.store)) + "`" data-pu='" + ('{0:F4}' -f [double]$s.per_unit) + "'>")
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
      $ranked = @($r.stores | Where-Object { -not (IsNoneCarry ([string]$r.id) ([string]$_.store)) } | Sort-Object per_unit)
      if ($ranked.Count -eq 0) { continue }
      $totalCommodities++
      $unit = [string]$r.unit
      [void]$sb.Append("<article class='pg-row' data-cat='" + (HtmlEnc $riKey) + "' data-id='" + [string]$r.id + "'>")
      $sumHtml = SummaryHtml $ranked[0] $unit
      [void]$sb.Append("<div class='pg-rowhead'><div class='pg-rh-top'><label class='pg-pickl' title='Add to my shopping list'><input type='checkbox' class='pg-pick' aria-label='Add to my shopping list'></label><span class='pg-name'>" + (HtmlEnc $r.commodity) + "</span><span class='pg-chev' aria-hidden='true'></span>" + $sumHtml + "</div><div class='pg-rh-bot'><span class='pg-unit'>" + (UnitLabel $unit) + "</span></div></div>")
      $cb = New-Object System.Text.StringBuilder
      $i = 0
      foreach ($s in $ranked) {
        $totalPrices++
        $isBest = ($i -eq 0)
        $cls = 'pg-chip'; if ($isBest) { $cls += ' is-best' }
        $notes = @()
        if ([string]$s.store -eq "Sam's Club") { $notes += 'membership' }
        if ($s.bulk) { $notes += 'bulk' }
        [void]$cb.Append("<div class='" + $cls + "' data-store=`"" + (HtmlEnc ([string]$s.store)) + "`" data-pu='" + ('{0:F4}' -f [double]$s.per_unit) + "'>")
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
      # A commodities.json STAPLE priced only as a recipe ingredient (no staple row above) still owes shoppers
      # all 7 stores: this is its one and only row, and the coverage gate holds every registered staple to that
      # rule. Emit the full MissingCells set so every missing store shows an honest "No price yet"/"Doesn't carry"
      # tile. Pure recipe-only ingredients stay exempt (NoneCells) - 7 mostly-empty cards on a niche item is noise.
      if ($stapleIdSet.ContainsKey([string]$r.id) -and -not $stapleRendered.ContainsKey([string]$r.id)) {
        [void]$cb.Append((MissingCells ([string]$r.id) (@($ranked | ForEach-Object { [string]$_.store }))))
      } else {
        [void]$cb.Append((NoneCells ([string]$r.id)))
      }
      # recipe rows get their own key (see the staple note): the same id can also exist as a weekly staple row
      # with a DIFFERENT unit and price set, so the two must not share one chip-feed entry.
      $boardChips[([string]$r.id + '::r')] = $cb.ToString()
    [void]$sb.Append("<div class='pg-stores' data-lazy='1' data-ck='" + (HtmlEnc ([string]$r.id)) + "::r'></div></article>")
    }
    [void]$sb.Append("</section>")
  }
}

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
[void]$sb.Append("<div class='pg-tripbar' id='pg-tripbar' hidden><span class='pg-trip-n' id='pg-trip-n'>0 items</span><button class='pg-trip-plan' id='pg-trip-plan'>Plan my trip &uarr;</button><button class='pg-trip-clear' id='pg-trip-clear'>Clear</button></div>")
[void]$sb.Append("</div>")
$body = $sb.ToString()

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
.pg-capture{display:flex;align-items:center;gap:14px;flex-wrap:wrap;margin:.8em 0 .2em;padding:12px 16px;border:1.5px solid var(--gold,#c9a227);border-radius:12px;background:rgba(201,162,39,.06)}
.pg-capture-txt{flex:1 1 260px;font-size:.92em;line-height:1.35;color:var(--ink)}
.pg-capture-btn{flex:0 0 auto;display:inline-block;padding:9px 16px;border-radius:9px;background:var(--ink);color:#fff !important;font-weight:700;font-size:.9em;text-decoration:none;white-space:nowrap}
.pg-capture-btn:hover{opacity:.88}
.pg-bar{position:fixed;left:0;right:0;bottom:-120px;z-index:9999;display:flex;align-items:center;gap:10px;padding:11px 14px;background:var(--ink);color:#fff;box-shadow:0 -4px 18px rgba(0,0,0,.18);transition:bottom .35s ease}
.pg-bar.pg-bar-on{bottom:0}
.pg-bar-txt{flex:1 1 auto;font-size:.86em;line-height:1.3}
.pg-bar-btn{flex:0 0 auto;padding:8px 14px;border-radius:8px;background:var(--gold,#c9a227);color:var(--ink) !important;font-weight:700;font-size:.86em;text-decoration:none;white-space:nowrap}
.pg-bar-x{flex:0 0 auto;background:none;border:none;color:#fff;opacity:.7;font-size:1.25em;line-height:1;padding:4px 8px;cursor:pointer}
.pg-bar-x:hover{opacity:1}
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
/* price records */
.pg-recband{margin:12px 0 6px;padding:14px 16px 12px;border:1px solid #ecd9ae;border-radius:14px;background:#fdf8ec}
.pg-recband-h{display:block;font-size:.7em;font-weight:700;text-transform:uppercase;letter-spacing:.09em;color:#8a6d1f;margin-bottom:11px}
.pg-recband-row{display:flex;flex-wrap:wrap;gap:9px}
.pg-recchip{display:flex;flex-direction:column;gap:2px;min-width:112px;padding:9px 12px 8px;border-radius:10px;background:#fff;border:1px solid #eee3c8}
.pg-recchip b{font-size:1.12em;font-weight:800;line-height:1.1;color:var(--green-d)}
.pg-recchip span{font-size:.82em;font-weight:700;color:var(--ink)}
.pg-recchip em{font-style:normal;font-size:.7em;font-weight:700;letter-spacing:.03em;color:#8a6d1f}
.pg-recband-sub{display:block;margin-top:9px;font-size:.74em;color:var(--mut)}
.pg-rec{display:inline-block;margin-left:0;padding:2px 9px 2px;border-radius:999px;font-size:.6em;font-weight:800;letter-spacing:.06em;text-transform:uppercase;white-space:nowrap;vertical-align:2px}
.pg-rec-low{background:var(--green);color:#fff}
.pg-rec-tie{background:var(--green-t);color:var(--green-d);border:1px solid var(--green)}
.pg-rec-dip{background:#fdf8ec;color:#8a6d1f;border:1px solid #ecd9ae}
.pg-stockup{background:#e2a43c;color:#16263f}
.pg-verd-buy{background:#fff;color:var(--green-d);border:1px solid var(--green)}
.pg-verd-wait{background:#f4f6f9;color:#68748a;border:1px solid #d5dbe4}
@media(max-width:560px){.pg-recchip{min-width:calc(50% - 5px);flex:1 1 calc(50% - 5px)}}
/* scoreboard */
.pg-board{margin:20px 0 6px;padding:15px 16px 14px;border:1px solid var(--bd);border-radius:14px;background:var(--green-t)}
.pg-board-h{display:block;font-size:.7em;font-weight:700;text-transform:uppercase;letter-spacing:.09em;color:var(--green-d);margin-bottom:6px}
.pg-board-sub{font-size:.85em;line-height:1.4;color:var(--mut);margin:0 0 12px}
.pg-board-sub b{color:var(--green-d);font-weight:800}
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
.pg-rowhead{display:flex;flex-direction:column;gap:7px;margin-bottom:0;cursor:pointer}
.pg-row.pg-open .pg-rowhead{margin-bottom:10px}
.pg-rowhead:focus-visible{outline:2px solid var(--green);outline-offset:3px;border-radius:4px}
.pg-rh-top{display:flex;align-items:center;gap:8px}
.pg-rh-bot{display:flex;flex-wrap:wrap;align-items:center;gap:7px;padding-left:28px}
.pg-name{font-size:1.09em;font-weight:700;color:var(--ink);flex:0 1 auto;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
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
@media(max-width:560px){.pg-wrap{font-size:1.4rem}.pg-head h1{font-size:1.55em}.pg-chip{min-width:calc(50% - 4px);flex:1 1 calc(50% - 4px);max-width:none}.pg-score{min-width:calc(33% - 7px)}
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
      bar.querySelector('.pg-bar-x').addEventListener('click', function(){
        bar.classList.remove('pg-bar-on');
        try { localStorage.setItem('tcBarSnooze', String(Date.now())); } catch(e){}
      });
      bar.querySelector('.pg-bar-btn').addEventListener('click', function(){
        bar.classList.remove('pg-bar-on');
      });
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
      sum.innerHTML="<span class='pg-sum-p'>"+(p?p.textContent:'')+"</span><span class='pg-sum-s'>"+(s?s.textContent:'')+"</span>"+sale;
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
  function pgToggle(head){
    var row=head.closest('.pg-row'); if(!row) return;
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
    // END-OF-JOB CAPTURE. The list lives in this tab and dies with it - "send it to my phone" is a receipt
    // the shopper WANTS, not a marketing ask. mailto/copy need no backend and cannot be abused as a mail
    // relay; the weekly line beside them is the habit hook.
    var listTxt='My Thrifty Crew shopping trip ('+new Date().toLocaleDateString()+')\n';
    best.combo.slice().sort(function(a,b){return byStore[b].length-byStore[a].length;}).forEach(function(st){
      if(byStore[st].length===0) return;
      listTxt+='\n'+st.toUpperCase()+'\n'; byStore[st].forEach(function(n){ listTxt+='  - '+n+'\n'; });
    });
    listTxt+='\nPrices checked this morning: https://www.thriftycrew.com/omaha-grocery-prices/';
    html+='<div class="pg-plan-send">'+
      '<a class="pg-plan-mailto" href="mailto:?subject='+encodeURIComponent('My shopping trip - Thrifty Crew')+'&body='+encodeURIComponent(listTxt)+'">Email me this list</a>'+
      '<button class="pg-plan-copy" id="pg-plan-copy">Copy list</button>'+
      '<span class="pg-plan-weekly">Want the whole board every Friday? <a href="#/portal/signup/free" data-portal="signup/free">Free email &rarr;</a></span></div>';
    document.getElementById('pg-plan-out').innerHTML=html;
    var cpBtn=document.getElementById('pg-plan-copy');
    if(cpBtn){ cpBtn.addEventListener('click',function(){
      try { navigator.clipboard.writeText(listTxt).then(function(){ cpBtn.textContent='Copied!'; setTimeout(function(){cpBtn.textContent='Copy list';},2000); }); }
      catch(e){ cpBtn.textContent='Press Ctrl+C'; }
    }); }
    lastK=k;
  }
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
    if (@($h.history).Count -ge 3 -and $h.src -ne 'recipe') { $t = JStr2 ($id + '-price-omaha') }
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
  var ALERT_URL = 'https://smp-feed.ancient-snow-93df.workers.dev/alert';
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
    $histOut = Join-Path (Split-Path $root -Parent) 'public\price-history.json'   # C:\Codex\income\public\
    $histDir = Split-Path $histOut -Parent
    if (-not (Test-Path $histDir)) { New-Item -ItemType Directory -Force -Path $histDir | Out-Null }
    $histJson | Set-Content $histOut -Encoding UTF8
    $idIndex = '{' + ((@($entries | ForEach-Object { ($_ -split ':\{')[0] + ':1' })) -join ',') + '}'
    Write-Output ("history: {0} items -> public\price-history.json ({1} KB, lazily fetched); inline index {2} KB" -f $entries.Count, [math]::Round($histJson.Length/1KB,0), [math]::Round($idIndex.Length/1KB,1))
    # content-hash cache-bust (same reason as board.json: the feed is cached 30 min, the post can be newer)
    $hsha = New-Object System.Security.Cryptography.SHA1Managed
    $hhash = ([BitConverter]::ToString($hsha.ComputeHash([Text.Encoding]::UTF8.GetBytes($histJson))) -replace '-','').Substring(0,10).ToLower()
    $histUrl = 'https://smp-feed.ancient-snow-93df.workers.dev/price-history.json?v=' + $hhash
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
$boardJson | Set-Content $boardOut -Encoding UTF8
# CACHE-BUST WITH A CONTENT HASH. The feed is served with max-age=1800, so a freshly published post can fetch a
# 30-minute-old board.json - rows added since would find no key and never fill (seen live: 15 empty rows, and a
# store still showing its pre-fix chip count). The post and the feed MUST move together, so the URL changes
# whenever the content does.
$sha = New-Object System.Security.Cryptography.SHA1Managed
$bhash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($boardJson))) -replace '-','').Substring(0,10).ToLower()
$boardUrl = 'https://smp-feed.ancient-snow-93df.workers.dev/board.json?v=' + $bhash
$js = $js.Replace('__BOARD_URL__', $boardUrl)
Write-Output ("chips: {0} rows -> public\board.json ({1} KB, lazily injected); post keeps the per-row answer" -f $boardChips.Count, [math]::Round($boardJson.Length/1KB,0))

# ---- THE ALL-3 ASSERTION (Brad's rule, 2026-07-23): a tile that shows a price MUST carry a link. ----
# SeeLink now guarantees this by construction (exact link -> weekly-ad pill -> store-search fallback), but a
# construction guarantee without an assertion is one refactor away from silent regression - so scan the FINAL
# HTML: every pg-chip that contains a pg-price must contain an <a. Hard-fail the build (exit 2) on any
# violation; a build that fails here never reaches publish.
$finalHtml = ($css + $body + $js + $histBlock)
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



