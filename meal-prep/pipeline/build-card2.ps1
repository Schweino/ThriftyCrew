# build-card2.ps1 - V2 recipe card renderer (2026-07-26 cost-section redesign, piloted on
# brazilianstyle-pork-ribs-bowls before any batch adoption).
#
# Layout changes vs build-card.ps1:
#   * Source credit moves to the TOP of the body (renders under the injected blue stat rectangle
#     + disclaimer), no longer buried above the upsell.
#   * The three scattered cost surfaces (scaler everyday-cost line, "Current cheapest pricing" box,
#     "Estimated Everyday Cost" section) are REPLACED by ONE tabbed section "What This Batch Costs":
#     Customized pricing (DEFAULT: whole-package at cheapest, uncheck-what-you-own) | Everyday cost |
#     Current cheapest pricing. ALL tabs price WHOLE packages (ceil packages needed, min 1).
#   * Payload carries physical package metadata only; all prices hydrate from the promoted release.
#     per ingredient, enriched from the run's recipes-costed.json lines (-CostedFile).
#
# 2026-07-31 ELITE LAYER (income\design\design-elite-layer-2026-07-31.md), all inside ONE build wave
# because a 513-post republish is the expensive part:
#   * Design tokens + the shared motion helpers ride at the top of every body (lib\design-tokens.ps1).
#   * Jump nav (Ingredients / What it costs / Make it / Portion it / Cook mode) under the stat line.
#   * "What This Batch Costs" is a literal register RECEIPT: paper, tear edges, monospace quantities,
#     TOTAL under a double rule, ink stamp. Function untouched; the widget still owns the numbers.
#   * COST-COMPOSITION BAR above the receipt, computed at build time from the costed run's per-line
#     util_cost, which sums to cost_batch - so the shares are a real 100% of a published total, not a
#     second sum. This is the PRE-HYDRATION snapshot only: renderComp() in tpl2-scaler-prefix.html
#     rebuilds the same bar from the promoted release (whole-package basis) as soon as the feed lands,
#     so the two bases differ slightly by design. Both are cost; neither is mass.
#   * Make It steps carry id="stepN" (the JSON-LD has always pointed at those anchors; nothing did).
#   * Related-recipes footer: three real cards (next-cheapest same protein, a free-this-week pick,
#     an adjacent cuisine) instead of bare text links.
#   * Shop-This-Recipe hands the still-checked ingredient ids to the price board. It renders ONLY when
#     this recipe's board-id coverage clears -MinBidCoverage; a half-matched list is worse than none.
#
# Per-serving basis (Brad, 2026-07-26): whole-package total / servings, priced at current cheapest.
# The widget live-updates the stat rectangle from the feed; the static JSON-LD costPerServing is the
# everyday whole-package baseline (spec.head.costPerServing - the caller re-anchors it).
param(
  [Parameter(Mandatory=$true)][string]$SpecFile,
  [Parameter(Mandatory=$true)][string]$CostedFile,
  [Parameter(Mandatory=$true)][string]$OutDir,
  [string]$SiteBase = 'https://www.thriftycrew.com',
  [string]$Author = 'Thrifty Crew',
  [string]$RecipesDb = '',
  [string]$FreeRotation = '',
  [string]$PerServing = '',
  [double]$MinBidCoverage = 0.70
)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$spec = Get-Content $SpecFile -Raw | ConvertFrom-Json
# TOKEN EXPANSION AT THE RENDER BOUNDARY (2026-08-08). Spec prose stores {{cost_ps}}/{{cal}}/{{protein}}
# instead of literals; they resolve from THIS spec's own stat right here, so nothing downstream - the card
# body, the JSON-LD, the meta description - can ever quote a number the stat has moved away from. A spec
# still holding plain literals passes through untouched (expansion is a no-op without tokens).
. (Join-Path $here '..\lib\render-tokens.ps1')
$spec = Expand-SpecProse $spec
$spec = Move-SpecPriceToReleaseHydration $spec
$staticRecipeCost = [string]$spec.stat.cost_ps
$staticRecipeCostPattern = if($staticRecipeCost){ '\$' + [regex]::Escape($staticRecipeCost) } else { '(?!)' }
$utf8 = New-Object Text.UTF8Encoding($false)
. (Join-Path $here '..\..\lib\design-tokens.ps1')

# ---------- package model from the costed lines ----------
# cache the parsed costed file across same-process invocations (engine\build-cards.ps1 calls this
# script 513x with the same 5MB file; parsing once cuts the full-catalog build time dramatically)
if(-not $global:__tcCostedCache){ $global:__tcCostedCache=@{} }
if($global:__tcCostedCache.ContainsKey($CostedFile)){ $costed = $global:__tcCostedCache[$CostedFile] }
else { $costed = Get-Content $CostedFile -Raw | ConvertFrom-Json; $global:__tcCostedCache[$CostedFile] = $costed }
function Slugify([string]$s){ (($s.ToLower() -replace "[^a-z0-9]+","-").Trim('-')) }
$cr = $costed | Where-Object { ($_.PSObject.Properties.Name -contains 'slug' -and $_.slug -eq $spec.slug) -or $_.proposed_name -eq $spec.name }
# Fallback: display title can drift from the pipeline name (e.g. "...Bowls" vs "...Rice Bowl"); the slug
# is stable, so match on slugify(costed proposed_name) == spec.slug.
if(-not $cr){ $cr = $costed | Where-Object { (Slugify $_.proposed_name) -eq $spec.slug } }
if(($cr | Measure-Object).Count -gt 1){ throw ("ambiguous costed match for $($spec.slug): $((@($cr).Count)) entries") }
if(-not $cr){ throw "no costed entry for $($spec.slug) / $($spec.name)" }
$clines = @{}; foreach($l in $cr.lines){ $clines[$l.item] = $l }

# ---------- catalog side-files (related recipes, free rotation, per-serving manifest) ----------
# Same one-parse-per-process cache as the costed file: 513 invocations must not re-read a 2MB db 513x.
if(-not $global:__tcAuxCache){ $global:__tcAuxCache=@{} }
function Get-AuxJson([string]$path){
  if(-not $path -or -not (Test-Path $path)){ return $null }
  if($global:__tcAuxCache.ContainsKey($path)){ return $global:__tcAuxCache[$path] }
  $o = $null
  try { $o = Get-Content $path -Raw | ConvertFrom-Json } catch { $o = $null }
  $global:__tcAuxCache[$path] = $o
  return $o
}
if(-not $RecipesDb){ $RecipesDb = (Join-Path $here '..\recipes-db.json') }
if(-not $FreeRotation){ $FreeRotation = (Join-Path $here '..\free-rotation.json') }
if(-not $PerServing){ $PerServing = (Join-Path $here 'v2-perserving.json') }

# display names (with brand) come from ingredients_display, which build-specs emits in the SAME order
# as scaler.ing - the payload carries them so the JS can rewrite the Ingredients section when scaling.
if(@($spec.ingredients_display).Count -ne @($spec.scaler.ing).Count){
  throw ("display/scaler count mismatch: {0} vs {1} ({2})" -f @($spec.ingredients_display).Count, @($spec.scaler.ing).Count, $spec.slug)
}
$dispNames = @()
foreach($dl in $spec.ingredients_display){
  $m = [regex]::Match($dl, '^<strong>(.+?):</strong>')
  if(-not $m.Success){ throw ("cannot parse display name from '{0}' ({1})" -f $dl, $spec.slug) }
  $dispNames += $m.Groups[1].Value
}
$ingParts = @()
$compRows = @()      # build-time cost anatomy, read from the engine; never a second pricing model
$bidHave = 0; $bidMiss = @()
$di = -1
foreach($ing in $spec.scaler.ing){
  $di++
  $key = if($ing.PSObject.Properties.Name -contains 'canon' -and $ing.canon){ $ing.canon } else { $ing.item }
  $cl = $clines[$key]
  if(-not $cl){ throw ("no costed line for scaler item '{0}' (slug {1})" -f $key, $spec.slug) }
  # Package size comes from the recipe specification (pkg_g is the exact grams the engine rounds
  # on, drained-adjusted; NOT parsed from the freeform label). Buy item -> buy_*; bulk staple -> starter_*.
  $n = if($cl.buy_n){ [int]$cl.buy_n } else { [int]$cl.starter_n }
  $lbl = if($cl.pkg){ [string]$cl.pkg } else { [string]$cl.starter_pkg }
  $pkgG = if($cl.pkg_g){ [double]$cl.pkg_g } else { [double]$cl.starter_pkg_g }
  if($n -lt 1 -or -not $lbl -or $null -eq $pkgG -or $pkgG -le 0){ throw ("no whole-package data for '{0}' (slug {1}): n=$n lbl='$lbl' pkg_g=$pkgG" -f $key, $spec.slug) }
  # self-test: mirror the engine's own ceil(-0.02) - it must reproduce the engine's package count at base
  $chk = [math]::Max(1,[math]::Ceiling([double]$ing.grams / $pkgG - 0.02))
  if($chk -ne $n){ throw ("{0} ({1}): ceil({2}g/{3}g)={4} != engine {5} - pkg_g/buy_n disagree" -f $key,$spec.slug,$ing.grams,$pkgG,$chk,$n) }
  $p = '{"item":"' + ($ing.item -replace '"','\"') + '","disp":"' + ($dispNames[$di] -replace '"','\"') + '","grams":' + [int]$ing.grams + ',"buy":"' + ($ing.buy -replace '"','\"') + '"'
  if($ing.PSObject.Properties.Name -contains 'bid' -and $ing.bid){ $p += ',"bid":"' + $ing.bid + '","gpu":' + $ing.gpu; $bidHave++ } else { $bidMiss += [string]$ing.item }
  $p += ',"pkg_g":' + $pkgG + ',"pkg_l":"' + ($lbl -replace '"','\"') + '"}'
  $ingParts += $p
  # Composition is COST, because every label around this bar says cost and the widget's own renderComp()
  # rebuilds it from the promoted release as cost. This is not a second pricing model: util_cost is the
  # engine's per-line figure, and the lines sum to cost_batch exactly, so the shares are a real 100%.
  # (Until 2026-08-16 this read $ing.grams, so the bar ranked ingredients by MASS under cost wording -
  # potato read 22% of "this bill" on andong-jjimdak against a true 5%. Do not put grams back.)
  $compRows += [pscustomobject]@{ name = [string]$ing.item; cost = [double]$cl.util_cost }
}
$scalerData = '{"slug":"' + $spec.slug + '","base":14,"ing":[' + ($ingParts -join ',') + ']}'
$bidCoverage = if(@($spec.scaler.ing).Count -gt 0){ [double]$bidHave / @($spec.scaler.ing).Count } else { 0 }

# The widget template ships 513 times, so it goes over the wire minified (comments and indentation are
# load-bearing in the source file and pure weight in the post). Compressed once per process, not per slug.
if(-not $global:__tcTplCache){ $global:__tcTplCache=@{} }
$preKey = (Join-Path $here 'tpl2-scaler-prefix.html')
if(-not $global:__tcTplCache.ContainsKey($preKey)){
  $global:__tcTplCache[$preKey] = Compress-TcAsset ([IO.File]::ReadAllText($preKey, [Text.Encoding]::UTF8))
}
$prefix = $global:__tcTplCache[$preKey]
$suffix = [IO.File]::ReadAllText((Join-Path $here 'tpl2-scaler-suffix.html'), [Text.Encoding]::UTF8)
$scalerBlock = $prefix + $scalerData + $suffix

function Enc2([string]$s){ if($null -eq $s){ return '' }; return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;' -replace "'",'&#39;') }

# ---------- cost-composition bar (build time) ----------
# Nobody else on the internet shows a recipe's cost anatomy. One stacked bar, top three labeled, the rest
# folded into "everything else", and a payoff line that says out loud what the bar is showing.
function Build-CompBar($rows){
  $tot = 0.0; foreach($r in $rows){ $tot += [double]$r.cost }
  if($tot -le 0 -or @($rows).Count -lt 2){ return '' }
  $sorted = @($rows | Sort-Object -Property cost -Descending)
  $hues = @('#E2A43C','#1E3A5F','#5b7fa6')
  $segs = ''; $keys = ''
  $i = 0; $labeled = 0.0
  foreach($r in $sorted){
    $share = [double]$r.cost / $tot
    $hue = if($i -lt 3){ $hues[$i] } else { '#c3ccd8' }
    # data-i is the index in the ORIGINAL ingredient order so the widget can gray the right segment
    $orig = [array]::IndexOf(@($rows | ForEach-Object { $_.name }), [string]$r.name)
    $segs += "<i data-i='" + $orig + "' style='width:" + ('{0:N3}' -f ($share*100)) + "%;background:" + $hue + "' title='" + (Enc2 ([string]$r.name + ': ' + ('{0:P0}' -f $share))) + "'></i>"
    if($i -lt 3){ $keys += "<span><i style='background:" + $hue + "'></i>" + (Enc2 $r.name) + " " + ('{0:N0}' -f ($share*100)) + "%</span>"; $labeled += $share }
    $i++
  }
  if(@($sorted).Count -gt 3){ $keys += "<span><i style='background:#c3ccd8'></i>everything else " + ('{0:N0}' -f ((1-$labeled)*100)) + "%</span>" }
  $top1 = [double]$sorted[0].cost / $tot
  $top3 = 0.0; for($k=0; $k -lt [math]::Min(3,@($sorted).Count); $k++){ $top3 += [double]$sorted[$k].cost / $tot }
  $pay = if($top1 -ge 0.5){ "The " + [string]$sorted[0].name.ToLower() + " is the whole bill. Everything else is pocket change." }
         elseif($top3 -ge 0.7){ "Three items carry most of this bill. Get those cheap and the rest barely matters." }
         else { "No single item runs this bill, which is why the total stays low even when one thing goes up." }
  return "<div class='smp-comp'><div class='smp-comp-bar' role='img' aria-label='Share of the batch cost by ingredient'>" + $segs + "</div><div class='smp-comp-key'>" + $keys + "</div><p class='smp-comp-pay'>" + (Enc2 $pay) + "</p></div>"
}
$compHtml = Build-CompBar $compRows

# ---------- related recipes (build time, no JS) ----------
# Three real cards: the next-cheapest dinner with the same protein, one recipe that is FREE this week
# (badged, because the free five are the whole top of the funnel), and one adjacent cuisine.
function Build-Related($spec){
  $db = Get-AuxJson $RecipesDb
  if(-not $db){ return '' }
  $ps = @{}
  $psDoc = Get-AuxJson $PerServing
  if($psDoc){ foreach($e in $psDoc){ $ps[[string]$e.slug] = [double]$e.cheapest_ps } }
  $free = @{}
  $fr = Get-AuxJson $FreeRotation
  if($fr){ foreach($f in $fr.free){ $free[[string]$f.slug] = $true } }
  $me = [string]$spec.slug
  $myCost = if($ps.ContainsKey($me)){ $ps[$me] } else { 0 }
  $pool = @()
  foreach($r in $db.recipes){
    $sl = [string]$r.slug
    if($sl -eq $me){ continue }
    $cost = if($ps.ContainsKey($sl)){ $ps[$sl] } else { [double]$r.cost_per_serving }
    if($cost -le 0){ continue }
    $pool += [pscustomobject]@{ slug=$sl; name=[string]$r.name; cuisine=[string]$r.cuisine; protein=[string]$r.protein; cost=$cost; cal=[int]$r.per_serving.calories; pro=[int]$r.per_serving.protein_g; free=$free.ContainsKey($sl) }
  }
  if(@($pool).Count -lt 3){ return '' }
  $picks = @(); $taken = @{}
  function Take($cand){ foreach($c in @($cand)){ if($c -and -not $taken.ContainsKey($c.slug)){ $taken[$c.slug]=$true; return $c } }; return $null }
  $sameP = @($pool | Where-Object { $_.protein -eq [string]$spec.protein -and $_.cost -ge $myCost } | Sort-Object cost)
  if(-not @($sameP).Count){ $sameP = @($pool | Where-Object { $_.protein -eq [string]$spec.protein } | Sort-Object cost) }
  $a = Take $sameP
  $b = Take @($pool | Where-Object { $_.free } | Sort-Object cost)
  $c = Take @($pool | Where-Object { $_.cuisine -ne [string]$spec.cuisine -and $_.protein -eq [string]$spec.protein } | Sort-Object cost)
  if(-not $c){ $c = Take @($pool | Where-Object { $_.cuisine -ne [string]$spec.cuisine } | Sort-Object cost) }
  foreach($x in @($a,$b,$c)){ if($x){ $picks += $x } }
  # backfill so the row is never ragged: a two-card row reads like something failed to load
  if(@($picks).Count -lt 3){ foreach($x in @($pool | Sort-Object cost)){ if(-not $taken.ContainsKey($x.slug)){ $taken[$x.slug]=$true; $picks += $x }; if(@($picks).Count -ge 3){ break } } }
  $picks = @($picks | Select-Object -First 3)
  if(@($picks).Count -lt 3){ return '' }
  $cards = ''
  foreach($p in $picks){
    $badge = if($p.free){ "<span class='smp-rel-free'>Free this week</span>" } else { "<span class='smp-rel-cui'>" + (Enc2 $p.cuisine) + "</span>" }
    $cards += "<a class='smp-rel-card' href='" + $SiteBase + "/" + $p.slug + "/'>" + $badge + "<strong>" + (Enc2 $p.name) + "</strong><span class='smp-rel-m'>" + $p.cal + " cal &middot; " + $p.pro + "g protein</span><span class='smp-rel-p'><em>Current price loads on the recipe page</em></span></a>"
  }
  return "<div class='smp-rel'><span class='smp-rel-eyebrow'>Keep going</span><h2 class='smp-rel-h'>Three more for this week</h2><div class='smp-rel-grid'>" + $cards + "</div></div>"
}
$relHtml = Build-Related $spec

# ---------- prose (v2 order) ----------
$L = New-Object System.Collections.Generic.List[string]
# Tokens + shared motion helpers ride once at the top of every recipe body. Both blocks self-guard, so a
# page that somehow carries two of them still only installs one.
if(-not $global:__tcTplCache){ $global:__tcTplCache=@{} }
if(-not $global:__tcTplCache.ContainsKey('elite-recipe')){
  # A recipe post pays for the primitives it actually uses: no ledger tabs, no chalkboard, no board-only
  # receipt classes (the receipt here is .smp-rc), no full-screen-mode shell (Cook Mode brings its own).
  $global:__tcTplCache['elite-recipe'] = '<!--TC-ELITE-START--><style>' `
    + (Compress-TcCss (Get-TcTokenCss -Parts @('type','depth','money','focus','touch','motion','skel'))) `
    + (Compress-TcCss (Get-TcProvenanceCss)) `
    + (Compress-TcCss @'
.smp-rel{margin:2.8rem 0 1.4rem}
.smp-rel-eyebrow{display:block;font-size:1.05rem;font-weight:800;letter-spacing:.14em;text-transform:uppercase;color:#8a6d1f;margin:0 0 .35rem}
.smp-rel-h{font-family:Georgia,serif;font-size:2rem;letter-spacing:-.015em;color:#16263F;margin:0 0 1.2rem}
.smp-rel-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:1.1rem}
.smp-rel-card{display:flex;flex-direction:column;gap:.35rem;background:#fff;border:1px solid #e7e2d4;border-bottom:3px solid #ddd6c2;border-radius:14px;padding:1.2rem 1.3rem;text-decoration:none !important;transition:transform 200ms cubic-bezier(0.2,0,0,1),box-shadow 200ms cubic-bezier(0.2,0,0,1),border-color 200ms cubic-bezier(0.2,0,0,1)}
.smp-rel-card,.smp-rel-card *{text-decoration:none !important}
.smp-rel-card:active{transform:scale(.985)}
@media (hover:hover){.smp-rel-card:hover{transform:translateY(-1px);box-shadow:0 6px 16px rgba(22,38,63,.08);border-bottom-color:#E2A43C}}
.smp-rel-free{align-self:flex-start;background:#E2A43C;color:#16263F;font-size:1rem;font-weight:800;letter-spacing:.06em;text-transform:uppercase;padding:.2rem .7rem;border-radius:999px}
.smp-rel-cui{align-self:flex-start;color:#8a94a6;font-size:1.08rem;font-weight:700;letter-spacing:.05em;text-transform:uppercase}
.smp-rel-card strong{font-size:1.45rem;color:#16263F;line-height:1.3}
.smp-rel-m{font-size:1.15rem;color:#8a94a6}
.smp-rel-p{margin-top:.2rem;font-size:1.5rem;font-weight:750;color:#0c5c3b;font-variant-numeric:tabular-nums}
.smp-rel-p em{font-size:1.08rem;font-weight:500;font-style:normal;color:#8a94a6}
'@) + (Compress-TcCss (Get-TcPrintCss)) + '</style>' + (Compress-TcAsset (Get-TcMotionJs)) + '<!--TC-ELITE-END-->'
}
$L.Add($global:__tcTplCache['elite-recipe'])
$L.Add('')
if($spec.PSObject.Properties.Name -contains 'credit_html' -and $spec.credit_html){
  # Styled source callout (not buried, not hidden): gold-accent box, spaced off the print button below.
  $L.Add('<p class="smp-credit"><span class="smp-credit-eyebrow">Source</span> ' + $spec.credit_html + '</p>')
  $L.Add('')
}
$L.Add($scalerBlock)
$st = $spec.stat
$L.Add(('<p class="smp-stat"><strong>Makes 14 servings &middot; ~{0} cal &middot; {1}g protein &middot; {2}g carbs &middot; {3}g fat &middot; <span data-tc-live-price>current price loading</span>.</strong></p>' -f $st.cal,$st.protein,$st.carbs,$st.fat))
$L.Add('')
# JUMP NAV: these are 10-minute-read pages and cooks arrive mid-task. Cook mode is a button, not a link,
# because it builds itself from the Make It list at tap time (zero nodes until asked).
$L.Add('<nav class="smp-jump" aria-label="Jump to a section"><a href="#smp-ing">Ingredients</a><a href="#smp-cost">What it costs</a><a href="#smp-make">Make it</a><a href="#smp-portion">Portion it</a><button type="button" class="smp-jump-cook">Cook mode</button></nav>')
$L.Add('')
$L.Add('<p>' + $spec.intro_html + '</p>')
$L.Add('')
$L.Add('<h2 id="smp-ing">Ingredients</h2>')
$L.Add('<ul class="smp-ing">')
foreach($li in $spec.ingredients_display){ $L.Add('<li>' + $li + '</li>') }
$L.Add('</ul>')
$L.Add('')
# ---- combined cost section (the widget script in the scaler block fills it) ----
$L.Add('<div class="smp-ct"><h2 id="smp-cost">What This Batch Costs</h2>')
$L.Add('<p class="smp-ct-why"><em>Every price below hydrates from one promoted grocery release. Ghost stores the recipe narrative only.</em></p>')
if($compHtml){ $L.Add($compHtml) }
$L.Add('<p class="smp-ct-save" hidden></p>')
$L.Add('<div class="smp-ct-btns"><button type="button" class="smp-ct-btn on" data-t="custom">Customized pricing</button><button type="button" class="smp-ct-btn" data-t="everyday">Everyday cost</button><button type="button" class="smp-ct-btn" data-t="cheapest">Current cheapest pricing</button></div>')
$L.Add('<div class="smp-rc"><p class="smp-ct-sub"></p><ul class="smp-ct-list"></ul><p class="smp-rc-kitchen" hidden></p><p class="smp-rc-stamp"><span>Thrifty Crew &middot; Omaha</span></p></div>')
$L.Add('<p class="smp-sc-note">Totals price whole packages, cans, and jars, because that is how the register works. Change the servings in Make It Your Size above and these totals follow.</p>')
# SHOP THIS RECIPE ships only where the ingredient-to-board match is high enough to be useful. A list that
# silently drops a third of the basket is worse than no list; the coverage number decides, not optimism.
# 2026-08-08: the button no longer hands the basket to the price board (it wrote a localStorage payload
# nothing ever read, and dumped the reader on the board with their basket lost). It now opens the store
# picker in the widget: choose the stores you will actually walk into, then print the list split by store.
if($bidCoverage -ge $MinBidCoverage){
  # ABSOLUTE, like every other link on the card (the related-recipe cards already use $SiteBase). A RELATIVE
  # internal href is stored by Ghost as a placeholder and expanded to the absolute URL when the Admin API
  # reads it back, so the published bytes can never equal the local bytes - and publish.ps1's pre-flight
  # hashes the RAW body, so those slugs failed its live-vs-ledger check on every single run and had to be
  # -Force'd through. This was the only relative href in the whole card; it made exactly the 4 recipes that
  # render this note (the ones with an untracked ingredient) permanently un-republishable. [[ghost-url-roundtrip]]
  $miss = if(@($bidMiss).Count){ "<p class='smp-shop-note'>We do not track a board price for: " + (Enc2 (($bidMiss | Select-Object -First 4) -join ', ')) + ". <a href='" + $SiteBase + "/suggest-an-item/'>Ask us to add them</a>.</p>" } else { '' }
  $L.Add('<p style="margin:1.4rem 0 0"><button type="button" class="smp-shop">Shop this recipe</button></p>' + $miss)
}
$L.Add('</div>')
$L.Add('<p>' + $spec.cost_closing_html + '</p>')
$L.Add('')
$L.Add('<h2>Shop Smart</h2>')
$L.Add('<ul>')
foreach($li in $spec.shop_smart){ $L.Add('<li>' + $li + '</li>') }
$L.Add('</ul>')
$L.Add('')
$L.Add('<h2 id="smp-make">Make It</h2>')
$L.Add('<p class="smp-mi-resume" hidden></p>')
$L.Add('<ol class="smp-mi">')
$si = 0
foreach($li in $spec.make_it){ $si++; $L.Add('<li id="step' + $si + '">' + $li + '</li>') }
$L.Add('</ol>')
$L.Add('')
$L.Add('<h2 id="smp-portion">Portion It</h2>')
$L.Add('<p class="smp-portion">' + $spec.portion_html + '</p>')
$L.Add('')
if($relHtml){ $L.Add($relHtml); $L.Add('') }
$L.Add('<hr>')
$L.Add('<p><em>' + $spec.upsell_html + '</em></p>')
# The sticky mini-scaler lives at the end of the body so it is never inside a transformed ancestor
# (a transform on an ancestor makes position:fixed resolve against it, which would park the pill mid-page).
$L.Add('<div class="smp-mini" aria-hidden="false"><span class="smp-mini-l">servings</span><button type="button" class="smp-mini-dn" aria-label="One fewer serving">&minus;</button><button type="button" class="smp-mini-n" aria-label="Servings, tap for the full control">14</button><button type="button" class="smp-mini-up" aria-label="One more serving">+</button></div>')
$body = Remove-GhostStaticCurrencyClaims ($L -join "`n")

# ---- build-time self-checks (the elite-layer rule: enforced by a grep, not by a comment) ----
$navyBad = Test-TcNavyAdjacency -Html $body
if(@($navyBad).Count){ throw ("navy-band rule broken in " + $spec.slug + ": " + ($navyBad -join ' | ')) }
$goldBad = Test-TcGoldDiscipline -Html $body
if(@($goldBad).Count){ throw ("gold-discipline rule broken in " + $spec.slug + ": " + ($goldBad -join ' | ')) }
foreach($mk in @('smp-sc-data','smp-ct-list','smp-ct-btn','smp-ing','smp-mi','smp-jump-cook')){
  if($body -notmatch [regex]::Escape($mk)){ throw ("lost required hook '" + $mk + "' in " + $spec.slug) }
}

# ---------- head JSON-LD (nutrition and narrative only; no price authority) ----------
$slugUrl = "$SiteBase/$($spec.slug)/"
$steps = @()
$i = 0
foreach($sTxt in $spec.head.steps){
  $i++
  $nm = $sTxt
  if($spec.head.PSObject.Properties.Name -contains 'step_names' -and $spec.head.step_names -and $spec.head.step_names.Count -ge $i -and $spec.head.step_names[$i-1]){ $nm = $spec.head.step_names[$i-1] }
  $steps += [ordered]@{ '@type'='HowToStep'; text=$sTxt; name=$nm; url=("{0}#step{1}" -f $slugUrl,$i) }
}
$recipe = [ordered]@{
  '@context' = 'https://schema.org'
  '@type'    = 'Recipe'
  name        = $spec.name
  description = $spec.head.description
  author      = [ordered]@{ '@type'='Organization'; name=$Author }
  recipeCategory = 'Meal Prep'
  recipeCuisine  = $spec.cuisine
  recipeYield    = '14 servings'
  keywords       = $spec.head.keywords
  nutrition      = [ordered]@{
    '@type'='NutritionInformation'; servingSize='1 bowl'
    calories = ('{0} calories' -f $st.cal)
    proteinContent = ('{0} g' -f $st.protein)
    carbohydrateContent = ('{0} g' -f $st.carbs)
    fatContent = ('{0} g' -f $st.fat)
  }
  recipeIngredient   = @($spec.head.recipeIngredient)
  recipeInstructions = @($steps)
  image    = $spec.head.image
  prepTime = $spec.head.prepTime
  cookTime = $spec.head.cookTime
  totalTime= $spec.head.totalTime
}
$recipeJson = $recipe | ConvertTo-Json -Depth 8
# ---- THE PAYWALL CLAIM FOLLOWS THE RECIPE'S VISIBILITY (2026-08-31) --------------------------------
# This node was emitted UNCONDITIONALLY, so all 20 recipes in the free rotation told Google their
# content was behind a paywall while serving it to everyone. Those 20 are the entire top of the funnel:
# the pages whose only job is to be found and read by a non-member.
#
# Google's guidance is to mark paywalled content so it is not read as cloaking. Content that is free
# needs no such marking, and claiming it anyway asks Google to treat an open page as a closed one.
#
# THE CLAIM IS BAKED, AND THE ROTATION DOES NOT REBUILD CARDS. rotate-free-dinners flips Ghost
# visibility only ("visibility only - content, tags" are deliberately preserved), so a card built as
# paid stays marked paid after it is freed. sync-paywall-schema.ps1 is what keeps this true between
# builds, and the rotation calls it on every flip - exactly as it already republishes the hub for the
# same reason. This build-time conditional is the other half: a freshly built card starts out correct.
$isFreeNow = $false
try {
  $dbVis = Get-AuxJson $RecipesDb
  if ($dbVis) { foreach ($rv in $dbVis.recipes) { if ([string]$rv.slug -eq [string]$spec.slug) { $isFreeNow = ([string]$rv.visibility -eq 'public') } } }
} catch { $isFreeNow = $false }   # unknown visibility -> keep the paywall claim; understating access is the safe direction
$head = "<script type=`"application/ld+json`">`n" + $recipeJson + "`n</script>`n"
if (-not $isFreeNow) {
  $paywall = [ordered]@{ '@context'='https://schema.org'; '@type'='Article'; isAccessibleForFree=$false;
    hasPart=[ordered]@{ '@type'='WebPageElement'; isAccessibleForFree=$false; cssSelector='.gh-content' };
    mainEntityOfPage=$slugUrl; headline=$spec.name }
  $paywallJson = $paywall | ConvertTo-Json -Depth 6 -Compress
  $head += "<script type=`"application/ld+json`">`n" + $paywallJson + "`n</script>`n"
}
if($staticRecipeCost -and ($body -match $staticRecipeCostPattern -or $head -match $staticRecipeCostPattern)){
  throw ("static recipe price escaped promoted-release hydration for " + $spec.slug)
}
$nonMembershipBody = $body.Replace('$1 a month','')
if($nonMembershipBody -match '\$\d' -or $head -match '\$\d'){
  throw ("non-authoritative numeric price escaped Ghost narrative cleanup for " + $spec.slug)
}

if(-not (Test-Path $OutDir)){ New-Item -ItemType Directory -Force $OutDir | Out-Null }
[IO.File]::WriteAllText((Join-Path $OutDir ($spec.slug + '.body.html')), $body, $utf8)
[IO.File]::WriteAllText((Join-Path $OutDir ($spec.slug + '.head.html')), $head, $utf8)
# the coverage number is reported per slug so the batch aggregate is visible in the build log rather than
# something anyone has to go measure separately (elite-layer PRECONDITION on Shop This Recipe)
Write-Output ("built v2 {0}: body={1}B head={2}B bidcov={3:P0}{4}" -f $spec.slug, $body.Length, $head.Length, $bidCoverage, $(if($bidCoverage -lt $MinBidCoverage){ ' SHOP-OFF' } else { '' }))
