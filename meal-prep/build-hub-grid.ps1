# build-hub-grid.ps1 - Regenerates the /meal-prep-recipes/ hub recipe grid + filter counts + copy
# from recipes-db.json (all recipes). Derives data-protein from the heaviest real-meat ingredient.
#   -Validate : prove the deriver reproduces the current live categories (no write).
#   (default) : fetch live page, splice grid/counts/copy, write hub-new.html to scratchpad (no PUT).
#   -Publish  : also PUT the rebuilt page back to Ghost + re-verify live.
param([switch]$Validate,[switch]$Publish)
$ErrorActionPreference='Stop'
$root='C:\Codex\income\meal-prep'
# stable local work dir (was hardcoded to a long-gone session scratchpad - ratchet-class bug)
$scratch=Join-Path $env:TEMP 'tc-hub-work'
New-Item -ItemType Directory -Force $scratch | Out-Null
$apiUrl='https://map-to-success.ghost.io'
$doc=Get-Content (Join-Path $root 'recipes-db.json') -Raw | ConvertFrom-Json
$recipes=$doc.recipes
. (Join-Path $PSScriptRoot '..\lib\ghost-lib.ps1')   # 2026-07-26: single Ghost helper (was one of 50+ inline copies)
function New-GhostJWT { Get-GhostJWT -Key (Get-GhostKey) }

# --- protein deriver (heaviest real-meat ingredient; broths/stocks never count) ---
function Get-ProteinCat($rec){
  $best=$null; $bestG=-1
  foreach($ing in $rec.ingredients){
    $n=([string]$ing.item).ToLower()
    if($n -match 'broth|stock|bouillon|base\b|gravy'){ continue }
    $g=[double]$ing.grams; $cat=$null
    if($n -match 'turkey'){ $cat='turkey' }
    elseif($n -match 'chicken'){ $cat='chicken' }
    elseif($n -match 'ground beef|beef|steak|chuck|sirloin|brisket|\bkofta\b|meatball' -and $n -notmatch 'turkey|chicken|pork'){ $cat='beef' }
    elseif($n -match 'pork|sausage|chorizo|bacon|\bham\b|prosciutto|pancetta|kielbasa|carnitas|\bribs?\b'){ $cat='pork' }
    if($cat -and $g -gt $bestG){ $bestG=$g; $best=$cat }
  }
  return $best
}
function Enc($s){ ([string]$s).Replace('&','&amp;') }

if($Validate){
  $html=Get-Content (Join-Path $scratch 'hub-live.html') -Raw
  $live=@{}
  foreach($m in [regex]::Matches($html,'data-protein="([a-z]+)"[^>]*><h3>[^<]*</h3>.*?href="https://www\.thriftycrew\.com/([a-z0-9-]+)/"')){ $live[$m.Groups[2].Value]=$m.Groups[1].Value }
  $ok=0; $mm=@()
  foreach($kv in $live.GetEnumerator()){
    $rec=$recipes | Where-Object { $_.slug -eq $kv.Key }
    if(-not $rec){ $mm+="NO-DB $($kv.Key)"; continue }
    $d=Get-ProteinCat $rec
    if($d -eq $kv.Value){ $ok++ } else { $mm+="$($kv.Key): live=$($kv.Value) derived=$d" }
  }
  "live parsed:$($live.Count)  MATCH:$ok"; $mm | ForEach-Object { "  $_" }
  return
}

# --- build all cards, cost ascending ---
# 2026-07-26: card cost chips read the CURRENT-CHEAPEST whole-package per-serving from the v2 manifest
# (same basis as the recipe pages + top5 + rotation). recipes-db.cost_per_serving is the legacy
# utilization basis and only a fallback.
$cheapPs=@{}
try { (Get-Content (Join-Path $root 'pipeline\v2-perserving.json') -Raw | ConvertFrom-Json) | ForEach-Object { $cheapPs[[string]$_.slug]=[double]$_.cheapest_ps } } catch { Write-Warning 'v2-perserving.json unreadable - falling back to legacy cost_per_serving' }
$rows=@()
foreach($r in $recipes){
  # 2026-07-26: recipes-db.protein (stamped by normalize-recipe-ids, used by rotation + top5) is the
  # vetted source; the local name-regex is only a fallback (it misses e.g. Bratwurst - the r300
  # sausage lesson). Keeps every surface reading the SAME protein field.
  $cat=$null
  if($r.PSObject.Properties.Name -contains 'protein' -and $r.protein -in @('chicken','beef','pork','turkey')){ $cat=[string]$r.protein }
  if(-not $cat){ $cat=Get-ProteinCat $r }
  if(-not $cat){ throw "no protein category for $($r.slug)" }
  $rows += [pscustomobject]@{
    slug=$r.slug; name=(Enc $r.name); cuisine=(Enc $r.cuisine); cat=$cat
    cal=[int]$r.per_serving.calories; pro=[int]$r.per_serving.protein_g
    carb=[int]$r.per_serving.carbs_g; fat=[int]$r.per_serving.fat_g
    cost=$(if($cheapPs.ContainsKey([string]$r.slug)){ $cheapPs[[string]$r.slug] } else { [double]$r.cost_per_serving })
  }
}
$rows=$rows | Sort-Object cost, name
$counts=@{chicken=0;pork=0;beef=0;turkey=0}
$sb=New-Object System.Text.StringBuilder
foreach($c in $rows){
  $counts[$c.cat]++
  $cost='{0:0.00}' -f $c.cost
  [void]$sb.Append("<div class=""mpr-card"" data-protein=""$($c.cat)"" data-cal=""$($c.cal)""><h3>$($c.name)</h3><div class=""mpr-meta"">$($c.cuisine) &middot; 14 servings</div><div class=""mpr-macros""><div class=""mpr-b mpr-cal""><div class=""n"">$($c.cal)</div><div class=""l"">cal</div></div><div class=""mpr-b mpr-pro""><div class=""n"">$($c.pro)g</div><div class=""l"">protein</div></div><div class=""mpr-b mpr-carb""><div class=""n"">$($c.carb)g</div><div class=""l"">carbs</div></div><div class=""mpr-b mpr-fat""><div class=""n"">$($c.fat)g</div><div class=""l"">fat</div></div></div><div class=""mpr-cost""><div class=""c"">`$$cost <span>/ serving</span></div><a href=""https://www.thriftycrew.com/$($c.slug)/"">See it &rarr;</a></div></div>")
}
$cardsHtml=$sb.ToString()
$total=$rows.Count
"generated $total cards | chicken $($counts.chicken)  pork $($counts.pork)  beef $($counts.beef)  turkey $($counts.turkey)  sum $($counts.chicken+$counts.pork+$counts.beef+$counts.turkey)"

# --- fetch live page + splice ---
$jwt=New-GhostJWT
$g=Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/pages/slug/meal-prep-recipes/?formats=html&fields=id,html,updated_at" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}
$page=$g.pages[0]; $html=[string]$page.html
$orig=$html
# backup
$stamp=(Get-Content (Join-Path $root 'recipes-db.json') | Select-Object -First 0) # noop to keep style
$html | Set-Content (Join-Path 'C:\Codex\income\site-backups' 'meal-prep-recipes-BEFORE-213-grid.html') -Encoding UTF8

# 1) grid: replace everything between <div class="mpr-grid"> and the grid close before mpr-empty
$gm='<div class="mpr-grid">'
$gi=$html.IndexOf($gm); if($gi -lt 0){ throw 'grid open marker not found' }
$emptyTok='<div class="mpr-empty"'
$ei=$html.IndexOf($emptyTok,$gi); if($ei -lt 0){ throw 'mpr-empty not found' }
# region to keep after cards is the grid-closing </div> immediately before mpr-empty
$before=$html.Substring(0,$gi+$gm.Length)
$after=$html.Substring($ei)   # starts at <div class="mpr-empty"
$html=$before + $cardsHtml + '</div>' + $after

# 2) filter counts
$html=$html -replace 'data-p="chicken">Chicken <span class="mpr-fn">\d+</span>', ("data-p=""chicken"">Chicken <span class=""mpr-fn"">$($counts.chicken)</span>")
$html=$html -replace 'data-p="pork">Pork <span class="mpr-fn">\d+</span>', ("data-p=""pork"">Pork <span class=""mpr-fn"">$($counts.pork)</span>")
$html=$html -replace 'data-p="beef">Beef <span class="mpr-fn">\d+</span>', ("data-p=""beef"">Beef <span class=""mpr-fn"">$($counts.beef)</span>")
$html=$html -replace 'data-p="turkey">Turkey <span class="mpr-fn">\d+</span>', ("data-p=""turkey"">Turkey <span class=""mpr-fn"">$($counts.turkey)</span>")

# 3) copy: prose recipe-count mentions -> total.
# 2026-07-26 fix: the old .Replace('113 ...') was a ONE-WAY RATCHET - anchored to the original literal,
# so after the first run (113->213) later runs matched nothing and the number froze (Brad caught "All
# 213 recipes" at 513). Now: idempotent regex on ANY number in those phrases, PLUS the counts are
# wrapped in <span class="tc-rc"> markers that the site-wide head script live-updates from the feed's
# recipe_count - so the page is right even between rebuilds.
$rcSpan = '<span class="tc-rc">' + $total + '</span>'
$html=$html -replace '(?:<span class="tc-rc">)?\d+(?:</span>)?( high-protein meal prep dinners\.)', ($rcSpan + '$1')
$html=$html -replace 'All (?:<span class="tc-rc">)?\d+(?:</span>)?( recipes with full instructions)', ('All ' + $rcSpan + '$1')
$html=$html -replace '(?:<span class="tc-rc">)?\d+(?:</span>)?( high-protein dinners, macros from real)', ($rcSpan + '$1')
# store-count words in the static copy, DERIVED from the recipe board ("six" went stale at seven stores)
try {
  $storeWords=@{5='five';6='six';7='seven';8='eight';9='nine'}
  $cmpF = Get-ChildItem (Join-Path (Split-Path $root -Parent) 'grocery\out\comparison-*.json') | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  $rbCt=@(((Get-Content $cmpF.FullName -Raw | ConvertFrom-Json).comparison | ForEach-Object { $_.stores } | ForEach-Object { [string]$_.store }) | Sort-Object -Unique).Count
  if($rbCt -ge 5){
    $sw=$(if($storeWords.ContainsKey($rbCt)){ $storeWords[$rbCt] } else { [string]$rbCt })
    $html=$html -replace '\b(five|six|seven|eight|nine)( Omaha (?:grocery )?stores)', ($sw + '$2')
  }
} catch { Write-Warning 'store-count derivation skipped (recipe-board unreadable)' }

# 4) members-only recipe-suggestion form (idempotent; inserted UP TOP, just above the filter
#    bar / grid so members see it without scrolling past all 213 cards)
$formSrc=[IO.File]::ReadAllText((Join-Path $root 'recipe-request-form.html'),[Text.Encoding]::UTF8).Trim()
$plannerCta='<div style="margin:2.8rem 0 0;padding:20px 22px;background:#16263f;border-radius:16px;color:#fff"><span style="display:inline-block;background:#e2a43c;color:#16263f;font-weight:800;font-size:1.1rem;letter-spacing:.08em;border-radius:999px;padding:3px 12px;margin-bottom:8px">NEW &middot; MEMBER TOOL</span><h3 style="color:#fff;font-size:2rem;margin:.2rem 0 .5rem">Build your meal plan</h3><p style="margin:0 0 1.2rem;font-size:1.45rem;line-height:1.5;color:#c9d2de">Pick your dates, your household size, and your recipes. Get a cook night calendar, one combined grocery list, and live cheapest prices at Omaha stores.</p><a href="/meal-plan-builder/" style="display:inline-block;background:#e2a43c;color:#16263f;font-weight:800;padding:10px 22px;border-radius:999px;text-decoration:none;font-size:1.4rem">Open the Meal Plan Builder &rarr;</a></div>'
$formBlock='<!--RECIPE-SUGGEST-START-->'+$plannerCta+'<div class="mpr-suggest" style="margin:2.8rem 0">'+$formSrc+'</div><!--RECIPE-SUGGEST-END-->'
$rs='<!--RECIPE-SUGGEST-START-->'; $re='<!--RECIPE-SUGGEST-END-->'
# remove any existing block first (it may be at the old bottom position), then insert at the top anchor
$rsi=$html.IndexOf($rs)
if($rsi -ge 0){ $ree=$html.IndexOf($re,$rsi)+$re.Length; $html=$html.Substring(0,$rsi)+$html.Substring($ree) }
$anchor='<div class="mpr-filters">'
$ai=$html.IndexOf($anchor); if($ai -lt 0){ throw 'mpr-filters anchor not found for form insert' }
$html=$html.Substring(0,$ai)+$formBlock+$html.Substring($ai)

# --- guards ---
if($html -notmatch [regex]::Escape('id="smprrf-form"')){ throw 'recipe-suggest form missing after splice' }
if(([regex]::Matches($html,'<!--RECIPE-SUGGEST-START-->')).Count -ne 1){ throw 'recipe-suggest markers not unique' }
$nCards=([regex]::Matches($html,'<div class="mpr-card"')).Count
if($nCards -ne $total){ throw "card count $nCards != $total" }
if($counts.chicken+$counts.pork+$counts.beef+$counts.turkey -ne $total){ throw 'counts do not sum to total' }
if($html -match '113 high-protein'){ throw 'stale 113 copy remains' }
foreach($mk in @('<!--SMP-TOP5-->','<!--/SMP-TOP5-->','mp2-hero','mp2-offer','mpr-cta','mpr-empty','mpr-fbtns')){ if($html -notmatch [regex]::Escape($mk)){ throw "lost section: $mk" } }
# sanity: page not truncated
if($html.Length -lt $orig.Length){ Write-Warning "new html shorter than orig ($($html.Length) < $($orig.Length))" }
$html | Set-Content (Join-Path $scratch 'hub-new.html') -Encoding UTF8
"spliced OK: cards=$nCards  len $($orig.Length) -> $($html.Length)  written hub-new.html"

if($Publish){
  $lexObj=@{root=[ordered]@{children=@([ordered]@{type='html';version=1;html=$html});direction=$null;format='';indent=0;type='root';version=1}}
  $lex=ConvertTo-Json $lexObj -Depth 12 -Compress
  $body=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json @{pages=@(@{lexical=$lex;updated_at=$page.updated_at})} -Depth 6))
  $jwt=New-GhostJWT
  Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/pages/$($page.id)/" -Method Put -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -ContentType 'application/json' -Body $body | Out-Null
  Start-Sleep -Seconds 2
  $pub=(Invoke-WebRequest -Uri 'https://www.thriftycrew.com/meal-prep-recipes/' -UseBasicParsing -TimeoutSec 30).Content
  $liveCards=([regex]::Matches($pub,'<div class="mpr-card"')).Count
  $has213=($pub -match "$total high-protein meal prep dinners")
  "PUBLISHED. live cards=$liveCards  copy-updated=$has213"
}
