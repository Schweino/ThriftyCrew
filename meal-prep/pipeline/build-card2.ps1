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
#   * Payload v2 adds pkg_g (package grams) / pkg_p (everyday whole-package price) / pkg_l (label)
#     per ingredient, enriched from the run's recipes-costed.json lines (-CostedFile).
#
# Per-serving basis (Brad, 2026-07-26): whole-package total / servings, priced at current cheapest.
# The widget live-updates the stat rectangle from the feed; the static JSON-LD costPerServing is the
# everyday whole-package baseline (spec.head.costPerServing - the caller re-anchors it).
param(
  [Parameter(Mandatory=$true)][string]$SpecFile,
  [Parameter(Mandatory=$true)][string]$CostedFile,
  [Parameter(Mandatory=$true)][string]$OutDir,
  [string]$SiteBase = 'https://www.thriftycrew.com',
  [string]$Author = 'Thrifty Crew'
)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$spec = Get-Content $SpecFile -Raw | ConvertFrom-Json
$utf8 = New-Object Text.UTF8Encoding($false)

# ---------- package model from the costed lines ----------
$costed = Get-Content $CostedFile -Raw | ConvertFrom-Json
$cr = $costed | Where-Object { ($_.PSObject.Properties.Name -contains 'slug' -and $_.slug -eq $spec.slug) -or $_.proposed_name -eq $spec.name }
if(-not $cr){ throw "no costed entry for $($spec.slug) / $($spec.name)" }
$clines = @{}; foreach($l in $cr.lines){ $clines[$l.item] = $l }

function PkgGrams([string]$label,[double]$gpu){
  # package label -> grams. floz BEFORE oz (32floz must not match the oz rule).
  if($label -match '(\d+(?:\.\d+)?)\s*floz'){ return [math]::Round([double]$Matches[1]*29.5735,2) }
  if($label -match '(\d+(?:\.\d+)?)\s*oz'){ return [math]::Round([double]$Matches[1]*28.3495,2) }
  if($label -match '(\d+(?:\.\d+)?)\s*lb'){ return [math]::Round([double]$Matches[1]*453.592,2) }
  if($label -eq 'lb'){ return 453.592 }
  if($label -match 'head|each|ct pack|can|packet'){ if($gpu -gt 0){ return $gpu } }
  return 0
}

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
$di = -1
foreach($ing in $spec.scaler.ing){
  $di++
  $key = if($ing.PSObject.Properties.Name -contains 'canon' -and $ing.canon){ $ing.canon } else { $ing.item }
  $cl = $clines[$key]
  if(-not $cl){ throw ("no costed line for scaler item '{0}' (slug {1})" -f $key, $spec.slug) }
  $n = if($cl.buy_n){ [int]$cl.buy_n } else { [int]$cl.starter_n }
  $c = if($cl.buy_cost){ [double]$cl.buy_cost } else { [double]$cl.starter_cost }
  $lbl = if($cl.pkg){ [string]$cl.pkg } else { [string]$cl.starter_pkg }
  if($n -lt 1 -or $c -le 0 -or -not $lbl){ throw ("no whole-package data for '{0}' (slug {1})" -f $key, $spec.slug) }
  $gpu = 0.0; if($ing.PSObject.Properties.Name -contains 'gpu' -and $ing.gpu){ $gpu = [double]$ing.gpu }
  $pkgG = PkgGrams $lbl $gpu
  if($pkgG -le 0){ throw ("cannot derive package grams for '{0}' label '{1}'" -f $key, $lbl) }
  # self-test: the ceil model must reproduce the engine's package count at base servings
  $chk = [math]::Max(1,[math]::Ceiling([double]$ing.grams / $pkgG))
  if($chk -ne $n){ Write-Warning ("{0}: ceil({1}g/{2}g)={3} but engine bought {4} x {5} - using engine count basis" -f $key,$ing.grams,$pkgG,$chk,$n,$lbl) }
  $pkgP = [math]::Round($c / $n, 4)
  $p = '{"item":"' + ($ing.item -replace '"','\"') + '","disp":"' + ($dispNames[$di] -replace '"','\"') + '","grams":' + [int]$ing.grams + ',"buy":"' + ($ing.buy -replace '"','\"') + '"'
  if($ing.PSObject.Properties.Name -contains 'bid' -and $ing.bid){ $p += ',"bid":"' + $ing.bid + '","gpu":' + $ing.gpu }
  $p += ',"pkg_g":' + $pkgG + ',"pkg_p":' + $pkgP + ',"pkg_l":"' + ($lbl -replace '"','\"') + '"}'
  $ingParts += $p
}
$scalerData = '{"slug":"' + $spec.slug + '","base":14,"ing":[' + ($ingParts -join ',') + ']}'

$prefix = [IO.File]::ReadAllText((Join-Path $here 'tpl2-scaler-prefix.html'), [Text.Encoding]::UTF8)
$suffix = [IO.File]::ReadAllText((Join-Path $here 'tpl2-scaler-suffix.html'), [Text.Encoding]::UTF8)
$scalerBlock = $prefix + $scalerData + $suffix

# ---------- prose (v2 order) ----------
$L = New-Object System.Collections.Generic.List[string]
if($spec.PSObject.Properties.Name -contains 'credit_html' -and $spec.credit_html){
  $L.Add('<p><em>' + $spec.credit_html + '</em></p>')
  $L.Add('')
}
$L.Add($scalerBlock)
$st = $spec.stat
$L.Add(('<p><strong>Makes 14 servings &middot; ~{0} cal &middot; {1}g protein &middot; {2}g carbs &middot; {3}g fat &middot; ~${4} per serving (at everyday cost).</strong></p>' -f $st.cal,$st.protein,$st.carbs,$st.fat,$st.cost_ps))
$L.Add('')
$L.Add('<p>' + $spec.intro_html + '</p>')
$L.Add('')
$L.Add('<h2>Ingredients</h2>')
$L.Add('<ul class="smp-ing">')
foreach($li in $spec.ingredients_display){ $L.Add('<li>' + $li + '</li>') }
$L.Add('</ul>')
$L.Add('')
# ---- combined cost section (the widget script in the scaler block fills it) ----
$L.Add('<div class="smp-ct"><h2>What This Batch Costs</h2>')
$L.Add('<p class="smp-ct-why"><em>' + $spec.cost_note_html + '</em></p>')
$L.Add('<div class="smp-ct-btns"><button type="button" class="smp-ct-btn on" data-t="custom">Customized pricing</button><button type="button" class="smp-ct-btn" data-t="everyday">Everyday cost</button><button type="button" class="smp-ct-btn" data-t="cheapest">Current cheapest pricing</button></div>')
$L.Add('<p class="smp-ct-sub"></p>')
$L.Add('<ul class="smp-ct-list"></ul>')
$L.Add('<p class="smp-sc-note">Totals price whole packages, cans, and jars, because that is how the register works. Change the servings in Make It Your Size above and these totals follow.</p></div>')
$L.Add('<p>' + $spec.cost_closing_html + '</p>')
$L.Add('')
$L.Add('<h2>Shop Smart</h2>')
$L.Add('<ul>')
foreach($li in $spec.shop_smart){ $L.Add('<li>' + $li + '</li>') }
$L.Add('</ul>')
$L.Add('')
$L.Add('<h2>Make It</h2>')
$L.Add('<ol>')
foreach($li in $spec.make_it){ $L.Add('<li>' + $li + '</li>') }
$L.Add('</ol>')
$L.Add('')
$L.Add('<h2>Portion It</h2>')
$L.Add('<p>' + $spec.portion_html + '</p>')
$L.Add('')
$L.Add('<hr>')
$L.Add('<p><em>' + $spec.upsell_html + '</em></p>')
$body = $L -join "`n"

# ---------- head JSON-LD (unchanged shape; costPerServing comes from the spec) ----------
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
  costPerServing = [double]$spec.head.costPerServing
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
$paywall = [ordered]@{ '@context'='https://schema.org'; '@type'='Article'; isAccessibleForFree=$false;
  hasPart=[ordered]@{ '@type'='WebPageElement'; isAccessibleForFree=$false; cssSelector='.gh-content' };
  mainEntityOfPage=$slugUrl; headline=$spec.name }
$paywallJson = $paywall | ConvertTo-Json -Depth 6 -Compress
$head = "<script type=`"application/ld+json`">`n" + $recipeJson + "`n</script>`n<script type=`"application/ld+json`">`n" + $paywallJson + "`n</script>`n"

if(-not (Test-Path $OutDir)){ New-Item -ItemType Directory -Force $OutDir | Out-Null }
[IO.File]::WriteAllText((Join-Path $OutDir ($spec.slug + '.body.html')), $body, $utf8)
[IO.File]::WriteAllText((Join-Path $OutDir ($spec.slug + '.head.html')), $head, $utf8)
Write-Output ("built v2 {0}: body={1}B head={2}B" -f $spec.slug, $body.Length, $head.Length)
