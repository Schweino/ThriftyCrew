<#
  top5-weekly.ps1 - Re-costs all 113 recipes with THIS WEEK's grocery-board prices and maintains the
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
$root = $PSScriptRoot
$gout = Join-Path (Split-Path $PSScriptRoot -Parent) 'grocery\out'   # repo-relative (meal-prep and grocery are siblings)
# Ghost admin key: env var (GitHub Actions secret) first, then a gitignored local .ghostkey file, never source.
$adminKey = if ($env:GHOST_ADMIN_KEY) { $env:GHOST_ADMIN_KEY } elseif (Test-Path (Join-Path $PSScriptRoot '.ghostkey')) { (Get-Content (Join-Path $PSScriptRoot '.ghostkey') -Raw).Trim() } else { throw 'Ghost admin key missing: set $env:GHOST_ADMIN_KEY or create meal-prep\.ghostkey' }
$apiUrl   = "https://map-to-success.ghost.io"
function New-GhostJWT {
  $id,$secret = $adminKey -split ':'
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $b64 = { param($b) [Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_') }
  $h='{"alg":"HS256","typ":"JWT","kid":"'+$id+'"}'; $pl='{"iat":'+$now+',"exp":'+($now+300)+',"aud":"/admin/"}'
  $si=(& $b64 ([Text.Encoding]::UTF8.GetBytes($h)))+'.'+(& $b64 ([Text.Encoding]::UTF8.GetBytes($pl)))
  $sb=New-Object byte[] ($secret.Length/2); for($i=0;$i -lt $sb.Length;$i++){$sb[$i]=[Convert]::ToByte($secret.Substring($i*2,2),16)}
  $hm=New-Object System.Security.Cryptography.HMACSHA256 (,$sb); return $si+'.'+(& $b64 ($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes($si))))
}

$mapDoc = Get-Content (Join-Path $root 'ingredient-map.json') -Raw | ConvertFrom-Json
$db     = (Get-Content (Join-Path $root 'recipes-db.json') -Raw | ConvertFrom-Json).recipes
$live   = (Get-Content (Join-Path $gout 'recipe-board.json') -Raw | ConvertFrom-Json).comparison
$floor  = (Get-Content (Join-Path $gout 'recipe-board-everyday.json') -Raw | ConvertFrom-Json).comparison

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
  $base = if ($r.cost_batch_true) { [double]$r.cost_batch_true } else { [double]$r.cost_batch }
  $wc = [math]::Round($base + $delta, 2)
  $costed.Add([pscustomobject]@{ slug=$r.slug; name=$r.name; calories=[int]$r.per_serving.calories; week_cost=$wc; per_serving=[math]::Round($wc/[int]$r.servings, 2); delta=[math]::Round($delta,2); sale_items=@($saleItems | Select-Object -Unique) })
}
$ranked = @($costed | Sort-Object per_serving, week_cost)
$wk = ''
try { $wk = [string]((Get-Content (Join-Path $gout 'recipe-board.json') -Raw | ConvertFrom-Json).week_of) } catch {}
([pscustomobject]@{ computed_at=(Get-Date).ToString('s'); week_of=$wk; recipes=$ranked } | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $gout 'recipe-costs.json') -Encoding UTF8
# DINNER filter (Brad 2026-07-08): rank only servings over 500 calories - small portions are always
# cheapest per serving, but they are snacks, not dinners. The full costed list still lands in the json.
$dinners = @($ranked | Where-Object { $_.calories -gt 500 })
# protein detection: the recipe's heaviest meat ingredient decides its tab (sausage/ham/bacon count as pork)
$byId2 = @{}; foreach ($r in $db) { $byId2[[string]$r.slug] = $r }
function ProteinOf($slug) {
  $r = $byId2[$slug]; $best = ''; $bg = 0
  foreach ($i in $r.ingredients) {
    $n = ([string]$i.item).ToLower(); $g = [double]$i.grams; $p = ''
    if ($n -match 'chicken') { $p = 'Chicken' }
    elseif ($n -match 'turkey') { $p = 'Turkey' }
    elseif ($n -match 'beef|steak') { $p = 'Beef' }
    elseif ($n -match 'pork|ham\b|sausage|bacon|carnitas') { $p = 'Pork' }
    if ($p -and $g -gt $bg) { $best = $p; $bg = $g }
  }
  return $best
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
$sec += "<p style='color:#64748b;font-size:1.4rem;margin:0 0 1.2rem'>Pick your protein. Real dinner-sized servings only, re-costed from this week's verified grocery prices at six Omaha stores.</p>"
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
  $sec += "<ol class='smp-t5-card' data-p='" + $pn + "' style='margin:0;padding-left:2.2rem;" + $(if (-not $first) { "display:none" }) + "'>"
  foreach ($t in $tabs[$pn]) {
    $saleTxt = if (@($t.sale_items).Count -gt 0) { " <span style='color:#b23b2e;font-weight:700;font-size:1.15rem'>" + @($t.sale_items).Count + " ingredient" + $(if (@($t.sale_items).Count -ne 1) { 's' }) + " on sale</span>" } else { "" }
    $sec += "<li style='margin:0 0 .9rem;font-size:1.55rem;color:#3a4658'><a href='/" + $t.slug + "/' style='color:#16263F;font-weight:700'>" + ($t.name -replace '&','&amp;' -replace '<','&lt;') + "</a> &middot; <b style='color:#0c5c3b'>$" + ('{0:F2}' -f $t.per_serving) + " a serving</b> &middot; " + $t.calories + " cal ($" + ('{0:F2}' -f $t.week_cost) + " for 14 servings)" + $saleTxt + "</li>"
  }
  $sec += "</ol>"
  $first = $false
}
$sec += "<p style='color:#8a94a6;font-size:1.15rem;margin:1.2rem 0 0'>Updated automatically when store prices change. Costs assume the cheapest verified price per ingredient; register totals vary by package size.</p>"
$sec += "<script>(function(){if(window.__smpT5)return;window.__smpT5=1;document.addEventListener('click',function(e){var b=e.target.closest('.smp-t5-tab');if(!b)return;var p=b.getAttribute('data-p');document.querySelectorAll('.smp-t5-tab').forEach(function(x){var on=x===b;x.style.background=on?'#16263F':'#fff';x.style.color=on?'#fff':'#16263F';});document.querySelectorAll('.smp-t5-card').forEach(function(c){c.style.display=(c.getAttribute('data-p')===p)?'':'none';});});})();</script>"
$sec += "</div><!--/SMP-TOP5-->"

$jwt = New-GhostJWT
$g = Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/pages/slug/meal-prep-recipes/?formats=html" -Headers @{Authorization="Ghost $jwt"}
$page = $g.pages[0]
$html = [string]$page.html
if ($html -match '<!--SMP-TOP5-->[\s\S]*?<!--/SMP-TOP5-->') {
  if ($html.Contains($sec)) { Write-Output "hub section unchanged - no publish"; exit 0 }
  $html = [regex]::Replace($html, '<!--SMP-TOP5-->[\s\S]*?<!--/SMP-TOP5-->', '')
}
$html = $sec + $html
$lexObj = @{root=[ordered]@{children=@([ordered]@{type='html';version=1;html=$html});direction=$null;format='';indent=0;type='root';version=1}}
$lex = ConvertTo-Json $lexObj -Depth 12 -Compress
$body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json @{pages=@(@{lexical=$lex;updated_at=$page.updated_at})} -Depth 6))
$jwt = New-GhostJWT
$r2 = Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/pages/$($page.id)/" -Method Put -Headers @{Authorization="Ghost $jwt"} -ContentType 'application/json' -Body $body
Write-Output "hub Top 5 section published"
