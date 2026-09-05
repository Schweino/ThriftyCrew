<#
  top5-weekly.ps1 - Re-costs all recipes in recipes-db (213) with THIS WEEK's grocery-board prices and maintains the
  "Top 5 cheapest recipes this week" section on the Meal Prep hub page (slug meal-prep-recipes).

  METHOD (honest, no invented prices): week_cost = cost_batch_true + delta, where delta sums each
  mapped ingredient's (grams / grams_per_unit) x (this week's cheapest per_unit - everyday-floor
  per_unit) from the live recipe board vs the monthly floor baseline. Ingredients without a confident
  board mapping contribute zero delta (their everyday price is already inside cost_batch_true).
  Ranking therefore moves ONLY on real, verified sale movements.

  Page update uses the LEXICAL single-html-card method (never ?source=html - it strips script/style).
  Idempotent via SMP-TOP5 markers; skips the PUT when the section is unchanged. Run daily after
  recipe-overlay (wired into check-ad-cycles.ps1).
#>
param([switch]$NoPublish)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = $PSScriptRoot
$gout = Join-Path (Split-Path $PSScriptRoot -Parent) 'grocery\out'   # repo-relative (meal-prep and grocery are siblings)
# Ghost admin key: env var (GitHub Actions secret) first, then a gitignored local .ghostkey file, never source.
$adminKey = if ($env:GHOST_ADMIN_KEY) { $env:GHOST_ADMIN_KEY } elseif (Test-Path (Join-Path $PSScriptRoot '.ghostkey')) { (Get-Content (Join-Path $PSScriptRoot '.ghostkey') -Raw).Trim() } else { throw 'Ghost admin key missing: set $env:GHOST_ADMIN_KEY or create meal-prep\.ghostkey' }
$apiUrl   = "https://map-to-success.ghost.io"
. (Join-Path $PSScriptRoot '..\lib\ghost-lib.ps1')   # 2026-07-26: single Ghost helper (was one of 50+ inline copies)
function New-GhostJWT { Get-GhostJWT -Key $adminKey }

$mapDoc = Read-JsonFile (Join-Path $root 'ingredient-map.json')
$db     = (Read-JsonFile (Join-Path $root 'recipes-db.json')).recipes
# 2026-07-26 cost-redesign: per_serving is now the CURRENT-CHEAPEST WHOLE-PACKAGE number (matches the
# recipe cards' headline + rectangle), read from the v2 manifest (pipeline\v2-perserving.json, regenerated
# weekly by compute-v2-perserving.ps1 off the live feed). The old cost_batch_true+delta basis is retained
# ONLY to detect this week's sale items for the badge. Recipes missing from the manifest fall back to the
# old basis so nothing drops.
$cheapestBySlug = @{}
try { (Read-JsonFile (Join-Path $root 'pipeline\v2-perserving.json')) | ForEach-Object { $cheapestBySlug[[string]$_.slug] = [double]$_.cheapest_ps } } catch { Write-Output 'WARN: v2-perserving.json unreadable - falling back to legacy per_serving basis' }
$live   = (Read-JsonFile (Join-Path $gout 'recipe-board.json')).comparison
$floor  = (Read-JsonFile (Join-Path $gout 'recipe-board-everyday.json')).comparison

# cheapest per_unit per board id, live vs floor (recipe-board mappings only; weekly-board mapped items
# contribute no delta - their everyday level is already baked into cost_batch_true)
function MinMap($rows) { $m=@{}; foreach ($r in $rows) { $lo=$null; foreach ($s in $r.stores) { $p=[double]$s.per_unit; if ($p -gt 0 -and ($null -eq $lo -or $p -lt $lo)) { $lo=$p } }; if ($lo) { $m[[string]$r.id]=$lo } }; return $m }
$liveMin  = MinMap $live
$floorMin = MinMap $floor
$ingMap = @{}
foreach ($m in $mapDoc.mappings) { if ($m.board -eq 'recipe') { $ingMap[[string]$m.item] = $m } }

$costed = New-Object System.Collections.Generic.List[object]
foreach ($r in $db) {
  if (-not ("" + $r.published -match '^\d{4}')) { continue }
  $delta = 0.0; $saleItems = @()
  foreach ($i in $r.ingredients) {
    $m = $ingMap[[string]$i.item]
    if (-not $m) { continue }
    $id = [string]$m.board_id
    if (-not ($liveMin.ContainsKey($id) -and $floorMin.ContainsKey($id))) { continue }
    $qty = [double]$i.grams / [double]$m.grams_per_unit
    $d = $qty * ($liveMin[$id] - $floorMin[$id])
    if ([math]::Abs($d) -gt 0.005) { $delta += $d; if ($d -lt 0) { $saleItems += [string]$i.item } }
  }
  $sv = [int]$r.servings; if($sv -le 0){ $sv = 14 }
  if ($cheapestBySlug.ContainsKey([string]$r.slug)) {
    $psv = $cheapestBySlug[[string]$r.slug]        # current cheapest whole-package per serving (headline basis)
    $wc  = [math]::Round($psv * $sv, 2)
  } else {
    $base = if ($r.cost_batch_true) { [double]$r.cost_batch_true } else { [double]$r.cost_batch }
    $wc = [math]::Round($base + $delta, 2); $psv = [math]::Round($wc / $sv, 2)
  }
  $costed.Add([pscustomobject]@{ slug=$r.slug; name=$r.name; calories=[int]$r.per_serving.calories; week_cost=$wc; per_serving=$psv; delta=[math]::Round($delta,2); sale_items=@($saleItems | Select-Object -Unique) })
}
$ranked = @($costed | Sort-Object per_serving, week_cost, slug)   # final slug key = deterministic tie-break so the free rotation (same 3-key sort) picks the identical top-5 on true double-ties
$wk = ''
try { $wk = [string]((Read-JsonFile (Join-Path $gout 'recipe-board.json')).week_of) } catch {}
([pscustomobject]@{ computed_at=(Get-Date).ToString('s'); week_of=$wk; recipes=$ranked } | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $gout 'recipe-costs.json') -Encoding UTF8
# DINNER filter (Brad 2026-07-08): rank only servings over 500 calories - small portions are always
# cheapest per serving, but they are snacks, not dinners. The full costed list still lands in the json.
$dinners = @($ranked | Where-Object { $_.calories -gt 500 })
# protein: recipes-db.protein, stamped by normalize-recipe-ids.ps1 from the heaviest protein ingredient
# BY CANONICAL ID (2026-07-25). The old inline name-regex disagreed with it at the edges (chicken BROTH
# voted chicken), and this tab set must be IDENTICAL to the free-rotation set - both sides now read the
# same field so "everything in this box is free" can be true by construction.
$byId2 = @{}; foreach ($r in $db) { $byId2[[string]$r.slug] = $r }
function ProteinOf($slug) {
  $r = $byId2[$slug]
  if ($r -and $r.PSObject.Properties['protein'] -and $r.protein) {
    $p = [string]$r.protein
    return ($p.Substring(0,1).ToUpper() + $p.Substring(1))
  }
  return ''
}
$tabs = [ordered]@{}
foreach ($pn in @('Pork','Chicken','Beef','Turkey')) {
  $list = @($dinners | Where-Object { (ProteinOf $_.slug) -eq $pn } | Select-Object -First 5)
  if ($list.Count -gt 0) { $tabs[$pn] = $list }
}
$top5 = @($dinners | Select-Object -First 5)   # kept for the console summary line
Write-Output ("costed " + $ranked.Count + " recipes; top5: " + (($top5 | ForEach-Object { $_.slug + ' $' + $_.per_serving }) -join ' | '))
if ($NoPublish) { exit 0 }

# ---- render + upsert the hub section ----
$sec = "<!--SMP-TOP5--><div class='smp-top5' style='margin:0 0 3rem;padding:2rem 2.2rem;background:#F6F1E7;border:1px solid #e5dcc8;border-radius:12px'>"
$sec += "<h2 style='font-family:Georgia,serif;color:#16263F;font-size:2.4rem;margin:0 0 .4rem'>Top 5 cheapest dinners this week (over 500 calories)</h2>"
# store count DERIVED from the WEEKLY comparison board (the "we price-check every morning" claim is
# about the weekly board's store set - the recipe board only carries 6 and would undercount).
$storeWords=@{5='five';6='six';7='seven';8='eight';9='nine'}
$storeCt=7
try {
  $cmpF = Get-ChildItem (Join-Path $gout 'comparison-*.json') | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  $storeCt=@(((Read-JsonFile $cmpF.FullName).comparison | ForEach-Object { $_.stores } | ForEach-Object { [string]$_.store }) | Sort-Object -Unique).Count
} catch {}
$storeWord=$(if($storeWords.ContainsKey($storeCt)){ $storeWords[$storeCt] } else { [string]$storeCt })
$sec += "<p style='color:#64748b;font-size:1.4rem;margin:0 0 1.2rem'>Pick your protein. Real dinner-sized servings only, re-costed from this week's verified grocery prices at $storeWord Omaha stores.</p>"
# FREE line (Brad 2026-07-25): the free-dinner rotation frees EXACTLY this box's recipes (same protein
# field, same >500-cal dinner filter, same top-5 rank). The claim is only printed when the rotation state
# file confirms the sets actually match - if they ever drift, the line silently drops and we warn, because
# a "free" promise that hits a paywall is worse than no promise.
try {
  $rotState = Read-JsonFile (Join-Path $root 'free-rotation.json')
  $freeSlugs = @($rotState.free | ForEach-Object { [string]$_.slug }) | Sort-Object
  $boxSlugs = @($tabs.Values | ForEach-Object { $_ } | ForEach-Object { [string]$_.slug }) | Sort-Object
  if (($freeSlugs -join ',') -eq ($boxSlugs -join ',')) {
    $sec += "<p style='color:#2e7d43;font-size:1.35rem;font-weight:600;margin:0 0 1.2rem'>Every dinner in this box is free to read right now. When prices re-rank the list, they return to members and the new cheapest take their place - members keep all " + $db.Count + " recipes every week.</p>"
  } else { Write-Output 'WARN: free-rotation set does not match the box - free line omitted (run rotate-free-dinners.ps1)' }
} catch { Write-Output ('WARN: could not read free-rotation state - free line omitted: ' + $_.Exception.Message) }
$sec += "<div style='display:flex;gap:8px;flex-wrap:wrap;margin:0 0 1.2rem'>"
$first = $true
foreach ($pn in $tabs.Keys) {
  $act = if ($first) { "background:#16263F;color:#fff;border-color:#16263F" } else { "background:#fff;color:#16263F;border-color:#16263F" }
  $sec += "<button type='button' class='smp-t5-tab' data-p='" + $pn + "' style='border:2px solid;border-radius:999px;padding:8px 20px;font-size:1.4rem;font-weight:700;cursor:pointer;font-family:inherit;" + $act + "'>" + $pn + "</button>"
  $first = $false
}
$sec += "</div>"
$first = $true
foreach ($pn in $tabs.Keys) {
  $sec += "<ul class='smp-t5-card' data-p='" + $pn + "' style='margin:0;padding:0;list-style:none;" + $(if (-not $first) { "display:none" }) + "'>"
  foreach ($t in $tabs[$pn]) {
    $ps = $byId2[$t.slug].per_serving
    $nm = ($t.name -replace '&','&amp;' -replace '<','&lt;')
    # clickable header row + hidden teaser panel (macros + this week's sale ingredients + link to the PAID
    # full recipe; the ingredient AMOUNTS and method stay behind the paywall on the recipe page)
    $sec += "<li style='margin:0 0 .7rem;border:1px solid #e5dcc8;border-radius:9px;overflow:hidden;background:#fff'>"
    $sec += "<div class='smp-t5-row' style='display:flex;justify-content:space-between;align-items:center;gap:10px;padding:.85rem 1.1rem;cursor:pointer'><span style='font-size:1.5rem;color:#16263F;font-weight:700'>" + $nm + "</span><span style='white-space:nowrap;font-size:1.35rem;color:#0c5c3b;font-weight:700'>$" + ('{0:F2}' -f $t.per_serving) + "/serving <span class='smp-t5-car' style='color:#8a94a6;font-weight:700'>+</span></span></div>"
    $sec += "<div class='smp-t5-det' style='display:none;padding:0 1.1rem 1.1rem;font-size:1.35rem;color:#3a4658'>"
    $sec += "<div style='display:flex;gap:18px;flex-wrap:wrap;margin:.2rem 0 .8rem'><span><b>" + $t.calories + "</b> cal</span><span><b>" + [int]$ps.protein_g + "g</b> protein</span><span><b>" + [int]$ps.carbs_g + "g</b> carbs</span><span><b>" + [int]$ps.fat_g + "g</b> fat</span></div>"
    if (@($t.sale_items).Count -gt 0) {
      $names = (@($t.sale_items) | Select-Object -First 4 | ForEach-Object { $_ -replace '&','&amp;' -replace '<','&lt;' }) -join ', '
      $sec += "<p style='color:#b23b2e;font-weight:600;margin:0 0 .7rem'>On sale this week: " + $names + "</p>"
    }
    $sec += "<p style='color:#64748b;margin:0 0 .9rem'>$" + ('{0:F2}' -f $t.week_cost) + " for the full 14-serving batch.</p>"
    $sec += "<a href='/" + $t.slug + "/' style='display:inline-block;background:#E2A43C;color:#16263F;font-weight:700;padding:9px 20px;border-radius:999px;text-decoration:none;font-size:1.3rem'>See the full recipe + grocery list &rarr;</a>"
    $sec += "</div></li>"
  }
  $sec += "</ul>"
  $first = $false
}
$sec += "<p style='color:#8a94a6;font-size:1.15rem;margin:1.2rem 0 0'>Tap any dinner for its macros and this week's sale ingredients. Updated automatically when store prices change; register totals vary by package size.</p>"
$sec += "<script>(function(){if(window.__smpT5)return;window.__smpT5=1;document.addEventListener('click',function(e){var b=e.target.closest('.smp-t5-tab');if(b){var p=b.getAttribute('data-p');document.querySelectorAll('.smp-t5-tab').forEach(function(x){var on=x===b;x.style.background=on?'#16263F':'#fff';x.style.color=on?'#fff':'#16263F';});document.querySelectorAll('.smp-t5-card').forEach(function(c){c.style.display=(c.getAttribute('data-p')===p)?'':'none';});return;}var row=e.target.closest('.smp-t5-row');if(row){var det=row.parentNode.querySelector('.smp-t5-det');var open=det.style.display!=='none';det.style.display=open?'none':'';var car=row.querySelector('.smp-t5-car');if(car)car.textContent=open?'+':'-';}});})();</script>"
$sec += "</div><!--/SMP-TOP5-->"

# ---- recipe-count banner (Brad 2026-07-25): show the catalog size up front, ABOVE the Top 5 box.
# Auto-counts from recipes-db so it grows with every run - no hard-coded number to go stale. Its own
# SMP-COUNT markers = independent idempotent upsert, inserted immediately before the Top 5 block.
$recipeCount = @($db).Count
$cntSec = "<!--SMP-COUNT--><div class='smp-count' style='margin:0 0 1.6rem;padding:1.8rem 2.2rem;background:#16263F;border-radius:12px;text-align:center;color:#fff'>"
$cntSec += "<div style='font-family:Georgia,serif;font-size:4.2rem;line-height:1;font-weight:700;color:#E2A43C'>" + $recipeCount + "</div>"
$cntSec += "<div style='font-size:1.5rem;font-weight:700;margin:.5rem 0 0;letter-spacing:.01em'>budget high-protein recipes, and counting</div>"
$cntSec += "<div style='font-size:1.25rem;color:#b9c4d4;margin:.35rem 0 0'>Every one re-costed weekly from real Omaha grocery prices. Members get them all for `$1/month.</div>"
$cntSec += "</div><!--/SMP-COUNT-->"

$jwt = New-GhostJWT
$g = Invoke-GhostApi -Uri "$apiUrl/ghost/api/admin/pages/slug/meal-prep-recipes/?formats=html" -Headers @{Authorization="Ghost $jwt"}
$page = $g.pages[0]
$html = [string]$page.html
$changed = $false

# COUNT block: replace in place if present, else insert directly before the Top 5 block (or prepend).
$ci = $html.IndexOf('<!--SMP-COUNT-->'); $cei = $html.IndexOf('<!--/SMP-COUNT-->')
if ($ci -ge 0 -and $cei -gt $ci) {
  $cEnd = '<!--/SMP-COUNT-->'.Length
  $cOld = $html.Substring($ci, $cei - $ci + $cEnd)
  if ($cOld -ne $cntSec) { $html = $html.Substring(0, $ci) + $cntSec + $html.Substring($cei + $cEnd); $changed = $true }
} else {
  $t5 = $html.IndexOf('<!--SMP-TOP5-->')
  if ($t5 -ge 0) { $html = $html.Substring(0, $t5) + $cntSec + $html.Substring($t5) } else { $html = $cntSec + $html }
  $changed = $true
}

# Replace IN PLACE between the markers so the section keeps its position in the redesigned page
# (the 2026-07-11 landing redesign put the Top-5 slot after the hero; the old remove-then-PREPEND
# behavior would shove it back above the hero every morning). Prepend only when no marker block exists.
$si = $html.IndexOf('<!--SMP-TOP5-->')
$ei = $html.IndexOf('<!--/SMP-TOP5-->')
if ($si -ge 0 -and $ei -gt $si) {
  $endLen = '<!--/SMP-TOP5-->'.Length
  $old = $html.Substring($si, $ei - $si + $endLen)
  if ($old -ne $sec) { $html = $html.Substring(0, $si) + $sec + $html.Substring($ei + $endLen); $changed = $true }
} else {
  $html = $sec + $html; $changed = $true
}
if (-not $changed) { Write-Output "hub sections unchanged - no publish"; exit 0 }
$lexObj = @{root=[ordered]@{children=@([ordered]@{type='html';version=1;html=$html});direction=$null;format='';indent=0;type='root';version=1}}
$lex = ConvertTo-Json $lexObj -Depth 12 -Compress
$body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json @{pages=@(@{lexical=$lex;updated_at=$page.updated_at})} -Depth 6))
$jwt = New-GhostJWT
$r2 = Invoke-GhostApi -Uri "$apiUrl/ghost/api/admin/pages/$($page.id)/" -Method Put -Headers @{Authorization="Ghost $jwt";'Content-Type'='application/json'} -Body $body
Write-Output "hub Top 5 section published"
