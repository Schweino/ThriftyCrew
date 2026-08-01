# build-hub-grid.ps1 - Regenerates the /meal-prep-recipes/ hub: recipe grid, filter panel, free-this-week
# rail, protein-per-dollar leaderboard, kitchen ticker, and the client script that drives all of it, from
# recipes-db.json + pipeline\v2-perserving.json + free-rotation.json.
#
#   -Validate : prove the deriver reproduces the current live categories (no write).
#   (default) : fetch live page, splice every managed block, write hub-new.html to scratchpad (no PUT).
#   -Publish  : also PUT the rebuilt page back to Ghost + re-verify live.
#
# 2026-07-31 REDESIGN (income\design\redesign-board-mealprep-2026-07-31.md hub P0-1..P2-5, plus the elite
# layer's hub section). Everything this script writes into the page lives between MARKERS and is replaced
# wholesale on every run, so a rebuild is idempotent and nothing accumulates:
#     <!--TC-HUB-CSS-->      design tokens + hub styles + print styles
#     <!--TC-HUB-RAIL-->     free-this-week snap rail + kitchen ticker
#     <!--TC-HUB-LEAD-->     protein-per-dollar leaderboard (navy band, static height, no JS)
#     <!--TC-HUB-FILTERS-->  search + protein + cuisine + sort + calories + the live results line
#     <!--TC-HUB-JS-->       filter/sort/FLIP/empty-state script
#
# HARD CONSTRAINT (unchanged): this is the live Google Ads landing page (AW-18314028055). The H1, the
# title tag and the top-of-page semantic structure are NOT touched, nothing here delays first paint of the
# hero text, and every block that fills in later has a FIXED HEIGHT so the page cannot shift under an ad
# click. Layout-shift regressions on this page cost real money through Quality Score.
#
# BAND ORDER IS DELIBERATE (elite-layer rule: never two navy bands adjacent). The blocks are inserted at
# the SAME anchor in reverse order, which lays them out as:
#     library intro -> free rail + ticker (white) -> planner CTA (navy) + suggest form (white)
#     -> leaderboard (navy) -> filters -> grid
# so the two navy panels are always separated by white. Test-TcNavyAdjacency re-checks it before write.
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
. (Join-Path $PSScriptRoot '..\lib\design-tokens.ps1')
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
function Attr($s){ ([string]$s -replace '&','&amp;' -replace '"','&quot;' -replace '<','&lt;' -replace '>','&gt;') }
# Cuisine casing: "german" and "palestinian" were rendering next to "Korean" and "Tex-Mex", and the two
# spellings also split the same cuisine into two dropdown entries. Title Case every hyphen/space token.
function TitleCuisine([string]$s){
  if(-not $s){ return '' }
  $parts = [regex]::Split($s, '(\s+|-)')
  $out = ''
  foreach($p in $parts){
    if($p -match '^\s+$' -or $p -eq '-'){ $out += $p; continue }
    if($p.Length -eq 0){ continue }
    $out += $p.Substring(0,1).ToUpper() + $(if($p.Length -gt 1){ $p.Substring(1) } else { '' })
  }
  return $out
}

if($Validate){
  # Fetch the live page if the cached copy is missing. -Validate used to require someone to have already
  # dropped hub-live.html into a temp folder by hand, with no note saying so anywhere, which is a validator
  # that cannot be run being counted as a validator that passes.
  $liveF = Join-Path $scratch 'hub-live.html'
  if(-not (Test-Path $liveF)){
    Write-Output 'no cached hub-live.html - fetching the live page'
    (Invoke-WebRequest -Uri 'https://www.thriftycrew.com/meal-prep-recipes/' -UseBasicParsing -TimeoutSec 60).Content | Set-Content $liveF -Encoding UTF8
  }
  $html=Get-Content $liveF -Raw
  $live=@{}
  # The card markup changed in the 2026-07-31 redesign (div -> anchor, FREE ribbon between the open tag
  # and the h3). BOTH shapes are parsed on purpose: this validator runs against the LIVE page, which is
  # the old markup right up until the redesign publishes, and a validator that only understands the new
  # shape would silently parse zero cards for exactly one cycle and report a clean run.
  foreach($m in [regex]::Matches($html,'data-protein="([a-z]+)"[^>]*>(?:\s*<span[^>]*>[^<]*</span>)?\s*<h3>[^<]*</h3>.*?href="https://www\.thriftycrew\.com/([a-z0-9-]+)/"')){ $live[$m.Groups[2].Value]=$m.Groups[1].Value }
  foreach($m in [regex]::Matches($html,'href="https://www\.thriftycrew\.com/([a-z0-9-]+)/"[^>]*\sdata-protein="([a-z]+)"')){ $live[$m.Groups[1].Value]=$m.Groups[2].Value }
  if($live.Count -eq 0){ throw 'VALIDATE PARSED ZERO CARDS - the card regex no longer matches the live markup (rules-that-silently-disarm class). Fix the regex before trusting this run.' }
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

# --- data ---
# 2026-07-26: card cost chips read the CURRENT-CHEAPEST whole-package per-serving from the v2 manifest
# (same basis as the recipe pages + top5 + rotation). recipes-db.cost_per_serving is the legacy
# utilization basis and only a fallback.
$cheapPs=@{}
try { (Get-Content (Join-Path $root 'pipeline\v2-perserving.json') -Raw | ConvertFrom-Json) | ForEach-Object { $cheapPs[[string]$_.slug]=[double]$_.cheapest_ps } } catch { Write-Warning 'v2-perserving.json unreadable - falling back to legacy cost_per_serving' }
# free rotation: the five-per-protein weekly free dinners. This is the whole top of the funnel and it was
# completely invisible in the 513-card grid until now.
$freeSet=@{}; $freeList=@()
try {
  $fr=Get-Content (Join-Path $root 'free-rotation.json') -Raw | ConvertFrom-Json
  foreach($f in $fr.free){ $freeSet[[string]$f.slug]=$true }
} catch { Write-Warning 'free-rotation.json unreadable - FREE badges will be absent this run' }

$rows=@()
foreach($r in $recipes){
  # 2026-07-26: recipes-db.protein (stamped by normalize-recipe-ids, used by rotation + top5) is the
  # vetted source; the local name-regex is only a fallback (it misses e.g. Bratwurst - the r300
  # sausage lesson). Keeps every surface reading the SAME protein field.
  $cat=$null
  if($r.PSObject.Properties.Name -contains 'protein' -and $r.protein -in @('chicken','beef','pork','turkey')){ $cat=[string]$r.protein }
  if(-not $cat){ $cat=Get-ProteinCat $r }
  if(-not $cat){ throw "no protein category for $($r.slug)" }
  $cost=$(if($cheapPs.ContainsKey([string]$r.slug)){ $cheapPs[[string]$r.slug] } else { [double]$r.cost_per_serving })
  $pro=[int]$r.per_serving.protein_g
  $rows += [pscustomobject]@{
    slug=[string]$r.slug; name=(Enc $r.name); cuisine=(TitleCuisine ([string]$r.cuisine)); cat=$cat
    cal=[int]$r.per_serving.calories; pro=$pro
    carb=[int]$r.per_serving.carbs_g; fat=[int]$r.per_serving.fat_g
    cost=$cost
    # protein per dollar: the brand argument in one number. Grams of protein you get for a dollar.
    ppd=$(if($cost -gt 0){ [math]::Round($pro / $cost, 1) } else { 0 })
    free=$freeSet.ContainsKey([string]$r.slug)
  }
}
$rows=$rows | Sort-Object cost, name
$counts=@{chicken=0;pork=0;beef=0;turkey=0}
$cuisines=@{}
$sb=New-Object System.Text.StringBuilder
foreach($c in $rows){
  $counts[$c.cat]++
  if($c.cuisine){ $cuisines[$c.cuisine]=$true }
  $cost='{0:0.00}' -f $c.cost
  $freeAttr = if($c.free){ ' data-free="1"' } else { '' }
  $ribbon   = if($c.free){ '<span class="mpr-free">Free this week</span>' } else { '' }
  # WHOLE CARD IS THE TAP TARGET, and it is a real anchor: the 513 recipe links stay in the HTML for SEO
  # exactly as before, they just stop being a 13px word in the corner of a 200px card.
  # "14 servings" is gone from every card (all 513 are 14 servings; the library intro says it once).
  [void]$sb.Append("<a class=""mpr-card"" data-protein=""$($c.cat)"" data-cal=""$($c.cal)"" data-cost=""$cost"" data-ppd=""$($c.ppd)"" data-cuisine=""$(Attr $c.cuisine)""$freeAttr href=""https://www.thriftycrew.com/$($c.slug)/"">$ribbon<h3>$($c.name)</h3><div class=""mpr-meta"">$($c.cuisine)</div><div class=""mpr-macros""><div class=""mpr-b mpr-cal""><div class=""n"">$($c.cal)</div><div class=""l"">cal</div></div><div class=""mpr-b mpr-pro""><div class=""n"">$($c.pro)g</div><div class=""l"">protein</div></div><div class=""mpr-b mpr-carb""><div class=""n"">$($c.carb)g</div><div class=""l"">carbs</div></div><div class=""mpr-b mpr-fat""><div class=""n"">$($c.fat)g</div><div class=""l"">fat</div></div></div><div class=""mpr-cost""><span class=""c"">`$$cost <span>/ serving</span></span><span class=""mpr-ppd"">$($c.ppd)g protein per `$1</span></div></a>")
}
$cardsHtml=$sb.ToString()
$total=$rows.Count
"generated $total cards | chicken $($counts.chicken)  pork $($counts.pork)  beef $($counts.beef)  turkey $($counts.turkey)  sum $($counts.chicken+$counts.pork+$counts.beef+$counts.turkey) | free $(@($rows | Where-Object { $_.free }).Count) | cuisines $($cuisines.Count)"

# ---------------------------------------------------------------------------------------------------
# MANAGED BLOCK 1: styles
# ---------------------------------------------------------------------------------------------------
$hubCss = Compress-TcCss ((Get-TcTokenCss -Parts @('type','depth','navy','money','focus','touch','motion','skel')) + @'
/* ---- card polish: protein-colored spine, pressable, whole-card anchor ---- */
.mpr-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:1.3rem}
.mpr-card{position:relative;background:#fff;border:1px solid #e7e2d4;border-bottom:3px solid #ddd6c2;border-left:3px solid #cbd5e1;border-radius:14px;padding:1.3rem 1.4rem;display:flex;flex-direction:column;text-decoration:none!important;color:inherit;
  content-visibility:auto;contain-intrinsic-size:auto 268px;transition:transform 100ms cubic-bezier(0.2,0,0,1),box-shadow 200ms cubic-bezier(0.2,0,0,1),border-color 200ms cubic-bezier(0.2,0,0,1)}
.mpr-card,.mpr-card *{text-decoration:none!important}
.mpr-card:active{transform:scale(.985)}
@media (hover:hover){.mpr-card:hover{box-shadow:0 6px 16px rgba(22,38,63,.08);border-bottom-color:#E2A43C}}
.mpr-card[data-protein=chicken]{border-left-color:#d99a3f}
.mpr-card[data-protein=pork]{border-left-color:#c4747f}
.mpr-card[data-protein=beef]{border-left-color:#a3453a}
.mpr-card[data-protein=turkey]{border-left-color:#5e8f6b}
.mpr-card h3{font-size:1.55rem;color:#16263F;margin:0 0 .2rem;line-height:1.25}
.mpr-meta{font-size:1.15rem;color:#94a3b8;margin-bottom:.9rem}
.mpr-free{position:absolute;top:-1px;right:12px;background:#E2A43C;color:#16263F;font-size:1rem;font-weight:800;letter-spacing:.05em;text-transform:uppercase;padding:.28rem .7rem;border-radius:0 0 8px 8px}
.mpr-card[data-free] h3{padding-right:96px}
.mpr-macros{display:flex;gap:.4rem;flex-wrap:wrap;margin-bottom:1rem}
.mpr-b{border-radius:8px;padding:.4rem .6rem;text-align:center;flex:1;min-width:56px}
.mpr-b .n{font-size:1.5rem;font-weight:800;line-height:1;font-variant-numeric:tabular-nums}
.mpr-b .l{font-size:1rem;text-transform:uppercase;letter-spacing:.03em;opacity:.8}
.mpr-cal{background:#eef2f7;color:#16263F}.mpr-pro{background:#e6f4ec;color:#1f6f4a}
.mpr-carb{background:#fdf3e3;color:#9a6a1a}.mpr-fat{background:#f6eef0;color:#8a3a4a}
.mpr-cost{margin-top:auto;display:flex;align-items:baseline;justify-content:space-between;gap:8px;border-top:1px dashed #e7e2d4;padding-top:.9rem;flex-wrap:wrap}
.mpr-cost .c{font-size:2rem;font-weight:750;color:#0c5c3b;font-variant-numeric:tabular-nums}
.mpr-cost .c span{font-size:1.15rem;font-weight:500;color:#94a3b8}
.mpr-ppd{font-size:1.1rem;color:#8a6d1f;font-weight:700;white-space:nowrap;font-variant-numeric:tabular-nums}
/* ---- FREE THIS WEEK rail: five cards, center snap, next-card peek, FIXED HEIGHT (zero CLS) ---- */
.mpr-rail-wrap{margin:0 0 2rem}
.mpr-rail-h{display:flex;align-items:baseline;justify-content:space-between;gap:12px;flex-wrap:wrap;margin:0 0 .8rem}
.mpr-rail-h h2{font-family:Georgia,serif;font-size:2rem;letter-spacing:-.015em;color:#16263F;margin:0}
.mpr-rail-h span{font-size:1.22rem;color:#64748b}
.mpr-rail{display:grid;grid-auto-flow:column;grid-auto-columns:78vw;gap:1rem;overflow-x:auto;scroll-snap-type:x mandatory;-webkit-overflow-scrolling:touch;padding:2px 2px 10px;scrollbar-width:thin}
.mpr-rail>a{scroll-snap-align:center;min-height:196px}
.mpr-dots{display:flex;gap:6px;justify-content:center;margin:.2rem 0 0}
.mpr-dots i{width:6px;height:6px;border-radius:999px;background:#cbd5e1;display:block}
.mpr-dots i.is-on{background:#E2A43C;width:18px}
@media(min-width:760px){.mpr-rail{grid-auto-columns:1fr;grid-auto-flow:row;grid-template-columns:repeat(5,1fr);overflow:visible}.mpr-dots{display:none}}
/* ---- kitchen ticker: one static stat line, build-time date, upgraded client side only when true ---- */
.mpr-ticker{display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin:0 0 2rem;padding:.85rem 1.1rem;background:#fdf8ec;border:1px solid #eee3c8;border-radius:12px;font-size:1.28rem;color:#3a4658;min-height:46px}
.mpr-ticker b{color:#16263F;font-variant-numeric:tabular-nums;font-weight:750}
.mpr-ticker .d{color:#8a94a6;font-size:1.14rem}
/* ---- protein-per-dollar leaderboard: navy band, static height, no JS ---- */
.mpr-lead{background:#16263F;border-radius:14px;padding:1.5rem 1.6rem;margin:0 0 2rem}
.mpr-lead .tc-eyebrow{color:#E2A43C}
.mpr-lead h2{font-family:Georgia,serif;font-size:1.9rem;letter-spacing:-.015em;color:#F6F1E7;margin:0 0 1rem}
.mpr-lead ol{list-style:none;margin:0;padding:0;counter-reset:mprl}
.mpr-lead li{counter-increment:mprl;display:flex;align-items:baseline;gap:12px;padding:.55rem 0;border-bottom:1px solid rgba(255,255,255,.10)}
.mpr-lead li:last-child{border-bottom:none}
.mpr-lead li::before{content:counter(mprl);color:#E2A43C;font-family:Georgia,serif;font-size:1.7rem;font-weight:700;min-width:20px;font-variant-numeric:tabular-nums}
.mpr-lead a{color:#F6F1E7!important;font-size:1.36rem;font-weight:700;text-decoration:none!important;flex:1;line-height:1.3}
.mpr-lead .v{color:#E2A43C;font-size:1.3rem;font-weight:750;white-space:nowrap;font-variant-numeric:tabular-nums}
.mpr-lead .fr{background:#E2A43C;color:#16263F;font-size:.95rem;font-weight:800;letter-spacing:.05em;text-transform:uppercase;padding:.15rem .5rem;border-radius:999px;white-space:nowrap}
.mpr-lead .fn{color:#8fa0b8;font-size:1.12rem;margin:.9rem 0 0;line-height:1.5}
/* ---- filters: one panel, and a one-line sticky version once you are past it ---- */
.mpr-filters{margin:0 0 1.7rem;padding:1.2rem 1.35rem;background:#f8fafc;border:1px solid #e7e2d4;border-bottom:3px solid #ddd6c2;border-radius:14px}
.mpr-frow{display:flex;align-items:center;gap:1rem;flex-wrap:wrap;margin-bottom:1rem}
.mpr-frow:last-of-type{margin-bottom:0}
.mpr-flabel{font-size:1.05rem;font-weight:700;text-transform:uppercase;letter-spacing:.05em;color:#64748b;min-width:78px}
.mpr-fbtns{display:flex;gap:.5rem;flex-wrap:wrap}
.mpr-fb{border:1px solid #cbd5e1;background:#fff;color:#475569;border-radius:999px;padding:.5rem 1.15rem;min-height:40px;font-size:1.2rem;font-weight:600;cursor:pointer;font-family:inherit;transition:transform 100ms cubic-bezier(0.2,0,0,1),border-color 200ms cubic-bezier(0.2,0,0,1)}
.mpr-fb:active{transform:scale(.985)}
.mpr-fb:hover{border-color:#1E3A5F;color:#16263F}
.mpr-fb.is-on{background:#16263F;border-color:#16263F;color:#fff}
.mpr-fn{opacity:.55;font-weight:500;margin-left:.2rem}
.mpr-fb.is-on .mpr-fn{opacity:.85}
.mpr-search{flex:1;min-width:180px;font-size:16px;padding:.6rem .9rem;border:1px solid #cbd5e1;border-radius:10px;font-family:inherit;color:#16263F;background:#fff;min-height:44px}
.mpr-sel{font-size:16px;padding:.55rem .7rem;border:1px solid #cbd5e1;border-radius:10px;font-family:inherit;color:#16263F;background:#fff;min-height:44px;max-width:100%}
.mpr-cal-ctl{display:flex;align-items:center;gap:.6rem;flex-wrap:wrap}
.mpr-cal-ctl input{width:96px;font-size:16px;padding:.5rem .7rem;border:1px solid #cbd5e1;border-radius:10px;font-family:inherit;color:#16263F;background:#fff;min-height:44px}
.mpr-cal-ctl input:focus,.mpr-search:focus,.mpr-sel:focus{outline:none;border-color:#E2A43C;box-shadow:0 0 0 3px rgba(226,164,60,.15)}
.mpr-cal-ctl .sep{color:#94a3b8;font-size:1.15rem}
.mpr-cal-ctl .unit{color:#94a3b8;font-size:1.05rem}
.mpr-clear{border:none;background:none;color:#1E3A5F;font-weight:700;font-size:1.1rem;cursor:pointer;text-decoration:underline;font-family:inherit;padding:.5rem;min-height:44px}
.mpr-count{font-size:1.24rem;color:#3a4658;font-weight:600;margin:0 0 1.1rem;padding:.55rem 0;position:sticky;top:0;background:#fff;z-index:3}
.mpr-count b{color:#16263F;font-variant-numeric:tabular-nums}
.mpr-empty{display:none;font-size:1.35rem;color:#3a4658;text-align:center;padding:2.2rem 1.4rem;background:#fdf8ec;border:1px solid #eee3c8;border-radius:14px;line-height:1.6}
.mpr-empty b{color:#16263F}
.mpr-relax{display:flex;gap:8px;flex-wrap:wrap;justify-content:center;margin:1rem 0 0}
.mpr-relax button{border:1px solid #E2A43C;background:#fff;color:#8a6d1f;border-radius:999px;padding:.5rem 1.1rem;min-height:40px;font-size:1.18rem;font-weight:700;cursor:pointer;font-family:inherit}
/* ---- tonight-mode picker ---- */
.mpr-tonight{margin:0 0 1.7rem;padding:1.2rem 1.35rem;background:#fff;border:1px solid #e7e2d4;border-bottom:3px solid #ddd6c2;border-radius:14px;min-height:96px}
.mpr-tonight-btn{display:inline-flex;align-items:center;min-height:44px;background:#E2A43C;color:#16263F;border:none;border-radius:10px;padding:.7rem 1.5rem;font-size:1.4rem;font-weight:800;cursor:pointer;font-family:inherit;transition:transform 100ms cubic-bezier(0.2,0,0,1)}
.mpr-tonight-btn:active{transform:scale(.985)}
.mpr-tonight-row{display:flex;gap:8px;flex-wrap:wrap;margin:.9rem 0 0}
.mpr-tonight-row button{border:1px solid #cbd5e1;background:#fff;color:#475569;border-radius:999px;padding:.45rem 1.05rem;min-height:40px;font-size:1.16rem;font-weight:600;cursor:pointer;font-family:inherit}
.mpr-tonight-out{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:1rem;margin:1.1rem 0 0}
.mpr-tonight-out:empty{display:none}
@media (prefers-reduced-motion:no-preference){.mpr-card.mpr-flip{transition:transform 300ms cubic-bezier(0.2,0,0,1)}}
'@ + (Get-TcPrintCss))
$cssBlock = '<!--TC-HUB-CSS-START--><style>' + $hubCss + '</style><!--TC-HUB-CSS-END-->'

# ---------------------------------------------------------------------------------------------------
# MANAGED BLOCK 2: free-this-week rail + kitchen ticker
# ---------------------------------------------------------------------------------------------------
# The rotation frees the five cheapest dinners PER PROTEIN, so this is twenty cards, not five. The rail
# shows the cheapest eight and says how many more are badged below; twenty cards in a snap rail is a
# scroll marathon on a phone and four rows of five on a desktop, and neither reads as a shelf.
$freeAll  = @($rows | Where-Object { $_.free } | Sort-Object cost)
$freeRows = @($freeAll | Select-Object -First 8)
$freeMore = @($freeAll).Count - @($freeRows).Count
$railCards = ''
foreach($f in $freeRows){
  $railCards += "<a class=""mpr-card"" data-protein=""$($f.cat)"" data-free=""1"" href=""https://www.thriftycrew.com/$($f.slug)/""><span class=""mpr-free"">Free</span><h3>$($f.name)</h3><div class=""mpr-meta"">$($f.cuisine)</div><div class=""mpr-macros""><div class=""mpr-b mpr-cal""><div class=""n"">$($f.cal)</div><div class=""l"">cal</div></div><div class=""mpr-b mpr-pro""><div class=""n"">$($f.pro)g</div><div class=""l"">protein</div></div></div><div class=""mpr-cost""><span class=""c"">`$$('{0:0.00}' -f $f.cost) <span>/ serving</span></span><span class=""mpr-ppd"">Free until Friday</span></div></a>"
}
$dots = ''
for($i=0;$i -lt @($freeRows).Count;$i++){ $dots += "<i" + $(if($i -eq 0){ " class='is-on'" } else { '' }) + "></i>" }
$railBlock = ''
if(@($freeRows).Count){
  $railSub = 'The five cheapest dinners for each protein are free every week. They rotate Fridays.'
  if($freeMore -gt 0){ $railSub += ' ' + $freeMore + ' more are badged in the library below.' }
  $railBlock = '<!--TC-HUB-RAIL-START--><div class="mpr-rail-wrap"><div class="mpr-rail-h"><h2>Free this week</h2><span>' + $railSub + '</span></div>' `
    + '<div class="mpr-rail" id="mpr-rail">' + $railCards + '</div><div class="mpr-dots" id="mpr-dots">' + $dots + '</div></div>'
  # KITCHEN TICKER. Every figure is computed here, from the same per-serving manifest the cards use.
  # The date is a BUILD-TIME date on purpose: this page does not rebuild daily, so a hardcoded "checked
  # this morning" would be a small lie most days. The script upgrades the wording only when the live
  # feed's own freshness stamp says today, and the guard below asserts the literal never ships.
  $avg = ($rows | Measure-Object -Property cost -Average).Average
  $under2 = @($rows | Where-Object { $_.cost -lt 2 }).Count
  $cheapest = ($rows | Measure-Object -Property cost -Minimum).Minimum
  $bestPpd = ($rows | Measure-Object -Property ppd -Maximum).Maximum
  $stamp = (Get-Date).ToString('MMM d')
  $railBlock += '<p class="mpr-ticker" id="mpr-ticker"><span>average dinner <b>$' + ('{0:N2}' -f $avg) + '</b></span><span class="d">&middot;</span><span><b>' + $under2 + '</b> of <b>' + $total + '</b> under $2</span><span class="d">&middot;</span><span>cheapest <b>$' + ('{0:N2}' -f $cheapest) + '</b></span><span class="d">&middot;</span><span>best value <b>' + ('{0:N1}' -f $bestPpd) + 'g</b> protein per $1</span><span class="d" id="mpr-fresh">prices from 7 Omaha stores, checked ' + $stamp + '</span></p><!--TC-HUB-RAIL-END-->'
}

# ---------------------------------------------------------------------------------------------------
# MANAGED BLOCK 3: protein-per-dollar leaderboard (ONE module, static height, no JS)
# ---------------------------------------------------------------------------------------------------
# Max two per protein so it reads like a menu rather than "chicken, chicken, chicken, chicken, chicken".
$leadPicks = @(); $perProtein = @{}
foreach($r in ($rows | Sort-Object -Property ppd -Descending)){
  $n = if($perProtein.ContainsKey($r.cat)){ [int]$perProtein[$r.cat] } else { 0 }
  if($n -ge 2){ continue }
  $perProtein[$r.cat] = $n + 1
  $leadPicks += $r
  if(@($leadPicks).Count -ge 5){ break }
}
$leadItems = ''
foreach($p in $leadPicks){
  $fr = if($p.free){ '<span class="fr">Free</span>' } else { '' }
  $leadItems += '<li><a href="https://www.thriftycrew.com/' + $p.slug + '/">' + $p.name + '</a>' + $fr + '<span class="v">' + ('{0:N1}' -f $p.ppd) + 'g / $1</span></li>'
}
$leadBlock = ''
if(@($leadPicks).Count -ge 3){
  $leadBlock = '<!--TC-HUB-LEAD-START--><div class="mpr-lead"><span class="tc-eyebrow">The value board</span><h2>The best protein deals this week</h2><ol>' + $leadItems + '</ol><p class="fn">Grams of protein per dollar, using this week&rsquo;s cheapest verified Omaha prices and whole packages. Two per protein, so it reads like a menu.</p></div><!--TC-HUB-LEAD-END-->'
}

# ---------------------------------------------------------------------------------------------------
# MANAGED BLOCK 4: the filter panel
# ---------------------------------------------------------------------------------------------------
$cuisOpts = ''
foreach($cu in ($cuisines.Keys | Sort-Object)){ $cuisOpts += '<option value="' + (Attr $cu) + '">' + (Enc $cu) + '</option>' }
$filtersBlock = '<!--TC-HUB-FILTERS-START-->' `
  + '<div class="mpr-tonight"><button type="button" class="mpr-tonight-btn" id="mpr-tonight">Pick 3 dinners for me</button>' `
  + '<div class="mpr-tonight-row"><button type="button" data-preset="cheap">Cheapest tonight</button><button type="button" data-preset="protein">Most protein per dollar</button><button type="button" data-preset="light">Under 500 calories</button><button type="button" data-preset="free">Free this week</button></div>' `
  + '<div class="mpr-tonight-out" id="mpr-tonight-out"></div></div>' `
  + '<div class="mpr-filters">' `
  + '<div class="mpr-frow"><span class="mpr-flabel">Search</span><input class="mpr-search" id="mpr-q" type="search" inputmode="search" enterkeyhint="search" placeholder="Search ' + $total + ' dinners: bulgogi, chili, casserole..." aria-label="Search recipes"></div>' `
  + '<div class="mpr-frow"><span class="mpr-flabel">Protein</span><div class="mpr-fbtns"><button class="mpr-fb is-on" data-p="all">All</button><button class="mpr-fb" data-p="chicken">Chicken <span class="mpr-fn">' + $counts.chicken + '</span></button><button class="mpr-fb" data-p="pork">Pork <span class="mpr-fn">' + $counts.pork + '</span></button><button class="mpr-fb" data-p="beef">Beef <span class="mpr-fn">' + $counts.beef + '</span></button><button class="mpr-fb" data-p="turkey">Turkey <span class="mpr-fn">' + $counts.turkey + '</span></button></div></div>' `
  + '<div class="mpr-frow"><span class="mpr-flabel">Cuisine</span><select class="mpr-sel" id="mpr-cuisine" aria-label="Cuisine"><option value="">All cuisines</option>' + $cuisOpts + '</select>' `
  + '<span class="mpr-flabel">Sort</span><select class="mpr-sel" id="mpr-sort" aria-label="Sort recipes"><option value="cost">Cheapest first</option><option value="ppd">Most protein per dollar</option><option value="cal">Lowest calories</option></select></div>' `
  + '<div class="mpr-frow"><span class="mpr-flabel">Calories</span><div class="mpr-cal-ctl"><input type="number" id="mpr-cmin" placeholder="min" min="0" step="10" inputmode="numeric" aria-label="Minimum calories"><span class="sep">to</span><input type="number" id="mpr-cmax" placeholder="max" min="0" step="10" inputmode="numeric" aria-label="Maximum calories"><span class="unit">cal / serving</span><button class="mpr-clear" id="mpr-clear" type="button">Reset</button></div></div>' `
  + '</div><p class="mpr-count" id="mpr-count" aria-live="polite"></p><!--TC-HUB-FILTERS-END-->'

# ---------------------------------------------------------------------------------------------------
# MANAGED BLOCK 5: the script
# ---------------------------------------------------------------------------------------------------
$hubJs = Compress-TcAsset ((Get-TcMotionJs) + @'
<script>
(function(){
  var grid=document.querySelector(".mpr-grid");
  if(!grid) return;
  // Parse every card's numbers ONCE. Re-reading getAttribute inside a 513-iteration loop on every
  // keystroke is what turns a filter into a stutter on a mid-range phone.
  var cards=[].slice.call(grid.querySelectorAll(".mpr-card")).map(function(el){
    return {el:el, p:el.getAttribute("data-protein"), cal:+el.getAttribute("data-cal")||0,
            cost:+el.getAttribute("data-cost")||0, ppd:+el.getAttribute("data-ppd")||0,
            cu:(el.getAttribute("data-cuisine")||""), free:el.hasAttribute("data-free"),
            t:((el.querySelector("h3")||{}).textContent||"").toLowerCase()+" "+(el.getAttribute("data-cuisine")||"").toLowerCase()};
  });
  var q=document.getElementById("mpr-q"), cuisine=document.getElementById("mpr-cuisine"), sortSel=document.getElementById("mpr-sort");
  var cmin=document.getElementById("mpr-cmin"), cmax=document.getElementById("mpr-cmax");
  var count=document.getElementById("mpr-count"), clear=document.getElementById("mpr-clear"), empty=document.getElementById("mpr-empty");
  var curP="all", lastCheap=null;
  function state(){
    var lo=parseInt(cmin.value,10), hi=parseInt(cmax.value,10);
    return {p:curP, cu:cuisine?cuisine.value:"", q:(q?q.value:"").trim().toLowerCase(),
            lo:isNaN(lo)?0:lo, hi:isNaN(hi)?999999:hi};
  }
  // THE ONE FILTER FUNCTION. The empty state's relax chips call this with a modified state rather than
  // re-implementing the test, so "drop this constraint and you get 12 results" can never lie.
  function match(c,s){
    if(s.p!=="all" && c.p!==s.p) return false;
    if(s.cu && c.cu!==s.cu) return false;
    if(s.q && c.t.indexOf(s.q)<0) return false;
    if(c.cal<s.lo || c.cal>s.hi) return false;
    return true;
  }
  function countWith(s){ var n=0; for(var i=0;i<cards.length;i++){ if(match(cards[i],s)) n++; } return n; }
  function sorted(list){
    var k=sortSel?sortSel.value:"cost";
    return list.slice().sort(function(a,b){
      if(k==="ppd") return b.ppd-a.ppd || a.cost-b.cost;
      if(k==="cal") return a.cal-b.cal || a.cost-b.cost;
      return a.cost-b.cost || a.cal-b.cal;
    });
  }
  function relaxChips(s){
    var opts=[];
    if(s.q) opts.push({label:'Clear "'+s.q+'"', fix:function(){ q.value=""; }, n:countWith(Object.assign({},s,{q:""}))});
    if(s.cu) opts.push({label:"Any cuisine", fix:function(){ cuisine.value=""; }, n:countWith(Object.assign({},s,{cu:""}))});
    if(s.p!=="all") opts.push({label:"Any protein", fix:function(){ setProtein("all"); }, n:countWith(Object.assign({},s,{p:"all"}))});
    if(s.lo>0||s.hi<999999) opts.push({label:"Any calories", fix:function(){ cmin.value=""; cmax.value=""; }, n:countWith(Object.assign({},s,{lo:0,hi:999999}))});
    return opts.filter(function(o){ return o.n>0; }).sort(function(a,b){ return b.n-a.n; }).slice(0,3);
  }
  function renderEmpty(s){
    if(!empty) return;
    var bits=[];
    if(s.lo>0||s.hi<999999) bits.push("between "+s.lo+" and "+(s.hi>=999999?"any":s.hi)+" calories");
    if(s.cu) bits.push("in "+s.cu);
    if(s.p!=="all") bits.push("with "+s.p);
    var what = s.q ? ('matching "'+s.q+'"') : "";
    empty.innerHTML='<b>Nothing '+(what||"here")+(bits.length?" "+bits.join(", "):"")+" this week.</b><br>Widen one thing and there is plenty.";
    var opts=relaxChips(s);
    if(opts.length){
      var wrap=document.createElement("div"); wrap.className="mpr-relax";
      opts.forEach(function(o){
        var b=document.createElement("button"); b.type="button"; b.textContent=o.label+" ("+o.n+")";
        b.addEventListener("click",function(){ o.fix(); apply(true); });
        wrap.appendChild(b);
      });
      empty.appendChild(wrap);
    }
  }
  // THE SHUFFLE. Measure, reorder, invert, play - on the VISIBLE slice only. Offscreen cards jump
  // instantly under content-visibility, which is the whole point of capping the work at one screenful.
  function flip(order){
    var reduce=(window.TC&&window.TC.rm&&window.TC.rm());
    var vh=window.innerHeight||800, first=null;
    if(!reduce){
      first=[];
      for(var i=0;i<order.length && first.length<18;i++){
        var r=order[i].el.getBoundingClientRect();
        if(r.bottom>-40 && r.top<vh+40) first.push({c:order[i], y:r.top, x:r.left});
      }
    }
    var frag=document.createDocumentFragment();
    order.forEach(function(c){ frag.appendChild(c.el); });
    grid.appendChild(frag);
    if(!first || !first.length) return;
    var moved=0;
    first.forEach(function(f,i){
      var r=f.c.el.getBoundingClientRect();
      var dx=f.x-r.left, dy=f.y-r.top;
      if(Math.abs(dx)<1 && Math.abs(dy)<1) return;
      // travel is capped at one viewport: a card sliding 4,000px reads as a glitch, not as an answer
      if(Math.abs(dy)>vh){ f.c.el.style.opacity="0"; requestAnimationFrame(function(){ f.c.el.style.transition="opacity 300ms cubic-bezier(0.2,0,0,1)"; f.c.el.style.opacity=""; setTimeout(function(){ f.c.el.style.transition=""; },320); }); return; }
      moved++;
      f.c.el.style.transform="translate("+dx+"px,"+dy+"px)";
      f.c.el.style.transition="none";
    });
    if(!moved) return;
    requestAnimationFrame(function(){
      first.forEach(function(f,i){
        if(!f.c.el.style.transform) return;
        f.c.el.classList.add("mpr-flip");
        f.c.el.style.transitionDelay=(i*15)+"ms";
        f.c.el.style.transform="";
      });
      setTimeout(function(){ first.forEach(function(f){ f.c.el.classList.remove("mpr-flip"); f.c.el.style.transition=""; f.c.el.style.transitionDelay=""; }); },300+18*15+60);
    });
  }
  function apply(animate){
    var s=state(), shown=[], cheap=null;
    cards.forEach(function(c){
      var vis=match(c,s);
      c.el.style.display = vis ? "" : "none";
      if(vis){ shown.push(c); if(cheap===null||c.cost<cheap) cheap=c.cost; }
    });
    var order=sorted(shown);
    if(animate) flip(order); else { var frag=document.createDocumentFragment(); order.forEach(function(c){ frag.appendChild(c.el); }); grid.appendChild(frag); }
    if(count){
      var n=shown.length;
      var txt=n+" recipe"+(n===1?"":"s")+" match";
      if(cheap!==null) txt+=" \u00B7 cheapest is $"+cheap.toFixed(2)+" a serving";
      count.innerHTML="<b>"+txt+"</b>";
      lastCheap=cheap;
    }
    if(empty){ if(shown.length){ empty.style.display="none"; } else { renderEmpty(s); empty.style.display="block"; } }
  }
  function setProtein(p){
    curP=p;
    document.querySelectorAll(".mpr-fb").forEach(function(x){ x.classList.toggle("is-on", x.getAttribute("data-p")===p); });
  }
  document.querySelectorAll(".mpr-fb").forEach(function(b){ b.addEventListener("click",function(){ setProtein(b.getAttribute("data-p")); if(window.TC&&window.TC.tap)window.TC.tap(8); apply(true); }); });
  if(q) q.addEventListener("input",function(){ apply(false); });
  if(cuisine) cuisine.addEventListener("change",function(){ apply(true); });
  if(sortSel) sortSel.addEventListener("change",function(){ apply(true); });
  cmin.addEventListener("input",function(){ apply(false); }); cmax.addEventListener("input",function(){ apply(false); });
  clear.addEventListener("click",function(){ cmin.value=""; cmax.value=""; if(q)q.value=""; if(cuisine)cuisine.value=""; if(sortSel)sortSel.value="cost"; setProtein("all"); apply(true); });

  // TONIGHT MODE: the presets VISIBLY drive the real controls, so a first-timer learns the filter panel
  // by watching it move rather than by reading a label.
  var tOut=document.getElementById("mpr-tonight-out"), tBtn=document.getElementById("mpr-tonight");
  function preset(kind){
    clear.click();
    if(kind==="protein"){ sortSel.value="ppd"; }
    else if(kind==="light"){ cmax.value="500"; }
    else if(kind==="free"){ /* handled in pick() */ }
    apply(true);
  }
  function pick(kind){
    var s=state(), pool=cards.filter(function(c){ return match(c,s); });
    if(kind==="free"){ var f=pool.filter(function(c){ return c.free; }); if(f.length>=3) pool=f; }
    pool=sorted(pool);
    // free-rotation recipes first: they are the ones a non-member can actually open tonight
    pool.sort(function(a,b){ return (b.free?1:0)-(a.free?1:0); });
    var three=pool.slice(0,3);
    tOut.innerHTML="";
    three.forEach(function(c){ var cl=c.el.cloneNode(true); cl.style.display=""; cl.removeAttribute("data-cost"); tOut.appendChild(cl); });
    if(three.length){
      var again=document.createElement("button"); again.type="button"; again.className="mpr-clear"; again.textContent="Shuffle these";
      again.addEventListener("click",function(){ pool=pool.slice(1).concat(pool.slice(0,1)); tOut.innerHTML=""; pool.slice(0,3).forEach(function(c){ var cl=c.el.cloneNode(true); cl.style.display=""; tOut.appendChild(cl); }); tOut.appendChild(again); });
      tOut.appendChild(again);
    }
  }
  if(tBtn) tBtn.addEventListener("click",function(){ pick("cheap"); });
  document.querySelectorAll(".mpr-tonight-row button").forEach(function(b){
    b.addEventListener("click",function(){ preset(b.getAttribute("data-preset")); pick(b.getAttribute("data-preset")); });
  });

  // rail dots follow the scroll position (the rail is a real scroller, not a carousel widget)
  var rail=document.getElementById("mpr-rail"), dots=document.getElementById("mpr-dots");
  if(rail&&dots){
    rail.addEventListener("scroll",function(){
      var i=Math.round(rail.scrollLeft/(rail.clientWidth*0.82));
      [].slice.call(dots.children).forEach(function(d,n){ d.classList.toggle("is-on",n===i); });
    },{passive:true});
  }

  apply(false);

  // FRESHNESS, honestly. The build stamped a date. Only the live feed's own timestamp may upgrade the
  // wording to "checked this morning", and only when that timestamp is actually today.
  var fresh=document.getElementById("mpr-fresh");
  if(fresh){
    fetch("https://smp-feed.ancient-snow-93df.workers.dev/smp-feed.json").then(function(r){return r.ok?r.json():null;}).catch(function(){return null;}).then(function(f){
      if(!f||!f.generated) return;
      var g=new Date(f.generated), now=new Date();
      if(g.getFullYear()===now.getFullYear()&&g.getMonth()===now.getMonth()&&g.getDate()===now.getDate()){
        fresh.textContent="prices from 7 Omaha stores, checked this morning";
      }
    });
  }
  // FREE badges, honestly. The rotation flips daily-ish and this page rebuilds on publish, so the build
  // stamps the badges and the rotation's own feed corrects them in between.
  fetch("https://smp-feed.ancient-snow-93df.workers.dev/free-dinners.json").then(function(r){return r.ok?r.json():null;}).catch(function(){return null;}).then(function(fd){
    if(!fd||!fd.free||!fd.free.length) return;
    var live={}; fd.free.forEach(function(x){ live[x.slug]=1; });
    var changed=0;
    cards.forEach(function(c){
      var m=(c.el.getAttribute("href")||"").match(/thriftycrew\.com\/([a-z0-9-]+)\//);
      var isFree=!!(m&&live[m[1]]);
      if(isFree===c.free) return;
      changed++;
      c.free=isFree;
      var rib=c.el.querySelector(".mpr-free");
      if(isFree){ c.el.setAttribute("data-free","1"); if(!rib){ var s=document.createElement("span"); s.className="mpr-free"; s.textContent="Free this week"; c.el.insertBefore(s,c.el.firstChild); } }
      else { c.el.removeAttribute("data-free"); if(rib) rib.parentNode.removeChild(rib); }
    });
  });
})();
</script>
'@)
$jsBlock = '<!--TC-HUB-JS-START-->' + $hubJs + '<!--TC-HUB-JS-END-->'

# ---------------------------------------------------------------------------------------------------
# fetch live page + splice
# ---------------------------------------------------------------------------------------------------
$jwt=New-GhostJWT
$g=Invoke-GhostApi -Uri "$apiUrl/ghost/api/admin/pages/slug/meal-prep-recipes/?formats=html&fields=id,html,updated_at" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}
$page=$g.pages[0]; $html=[string]$page.html
$orig=$html
$html | Set-Content (Join-Path 'C:\Codex\income\site-backups' ('meal-prep-recipes-BEFORE-elite-' + (Get-Date -Format 'yyyy-MM-dd') + '.html')) -Encoding UTF8

# Replace a managed block, or insert it fresh at $anchor when this is the first run.
function Splice-Block([string]$doc,[string]$name,[string]$block,[string]$anchor){
  $s='<!--' + $name + '-START-->'; $e='<!--' + $name + '-END-->'
  $si=$doc.IndexOf($s)
  if($si -ge 0){
    $ei=$doc.IndexOf($e,$si); if($ei -lt 0){ throw "$name start marker without an end marker" }
    return $doc.Substring(0,$si) + $block + $doc.Substring($ei+$e.Length)
  }
  if(-not $block){ return $doc }
  $ai=$doc.IndexOf($anchor); if($ai -lt 0){ throw "anchor '$anchor' not found for $name" }
  return $doc.Substring(0,$ai) + $block + $doc.Substring($ai)
}

# 1) grid cards
$gm='<div class="mpr-grid">'
$gi=$html.IndexOf($gm); if($gi -lt 0){ throw 'grid open marker not found' }
$emptyTok='<div class="mpr-empty"'
$ei=$html.IndexOf($emptyTok,$gi); if($ei -lt 0){ throw 'mpr-empty not found' }
$html=$html.Substring(0,$gi+$gm.Length) + $cardsHtml + '</div>' + $html.Substring($ei)

# 2) the old filter panel + the old trailing filter script are replaced by managed blocks. Both are
#    matched by their ORIGINAL markup on the first run only; after that the markers own them.
if($html.IndexOf('<!--TC-HUB-FILTERS-START-->') -lt 0){
  $fs=$html.IndexOf('<div class="mpr-filters">')
  if($fs -ge 0){
    $fe=$html.IndexOf('<div class="mpr-grid">',$fs)
    if($fe -lt 0){ throw 'could not find the grid after the filter panel' }
    $html=$html.Substring(0,$fs) + '<!--TC-HUB-FILTERS-START--><!--TC-HUB-FILTERS-END-->' + $html.Substring($fe)
  }
}
if($html.IndexOf('<!--TC-HUB-JS-START-->') -lt 0){
  $needle='var cards=[].slice.call(document.querySelectorAll(".mpr-card"));'
  $ni=$html.IndexOf($needle)
  if($ni -ge 0){
    $ss=$html.LastIndexOf('<script>',$ni); $se=$html.IndexOf('</script>',$ni)
    if($ss -lt 0 -or $se -lt 0){ throw 'could not bound the legacy hub filter script' }
    $html=$html.Substring(0,$ss) + '<!--TC-HUB-JS-START--><!--TC-HUB-JS-END-->' + $html.Substring($se+9)
  }
}

# 3) managed blocks. INSERTED AT THE SAME ANCHOR IN REVERSE VISUAL ORDER (each insert lands directly
#    above the anchor, so the last insert ends up highest). See the band-order note at the top.
$anchor='<div class="mpr-filters">'
if($html.IndexOf('<!--TC-HUB-FILTERS-START-->') -ge 0){ $anchor='<!--TC-HUB-FILTERS-START-->' }
$html=Splice-Block $html 'TC-HUB-FILTERS' $filtersBlock $anchor
$html=Splice-Block $html 'TC-HUB-LEAD'    $leadBlock    '<!--TC-HUB-FILTERS-START-->'
$html=Splice-Block $html 'TC-HUB-RAIL'    $railBlock    '<!--RECIPE-SUGGEST-START-->'
$html=Splice-Block $html 'TC-HUB-JS'      $jsBlock      '<div class="mpr-cta">'
# styles ride directly after the page's own style block so a later rule always wins over an earlier one
$styleAnchor='<div class="mp2-hero">'
$html=Splice-Block $html 'TC-HUB-CSS' $cssBlock $styleAnchor

# 4) empty state that recovers (the script fills in the specifics; this is the no-JS floor)
$html=$html -replace '<div class="mpr-empty" id="mpr-empty">[^<]*</div>', '<div class="mpr-empty" id="mpr-empty"><b>No recipes match those filters.</b><br>Widen one thing and there is plenty.</div>'

# 5) filter counts (the managed filter block already carries them; these keep any stale copy honest)
$html=$html -replace 'data-p="chicken">Chicken <span class="mpr-fn">\d+</span>', ("data-p=""chicken"">Chicken <span class=""mpr-fn"">$($counts.chicken)</span>")
$html=$html -replace 'data-p="pork">Pork <span class="mpr-fn">\d+</span>', ("data-p=""pork"">Pork <span class=""mpr-fn"">$($counts.pork)</span>")
$html=$html -replace 'data-p="beef">Beef <span class="mpr-fn">\d+</span>', ("data-p=""beef"">Beef <span class=""mpr-fn"">$($counts.beef)</span>")
$html=$html -replace 'data-p="turkey">Turkey <span class="mpr-fn">\d+</span>', ("data-p=""turkey"">Turkey <span class=""mpr-fn"">$($counts.turkey)</span>")

# 6) copy: prose recipe-count mentions -> total.
# 2026-07-26 fix: the old .Replace('113 ...') was a ONE-WAY RATCHET - anchored to the original literal,
# so after the first run (113->213) later runs matched nothing and the number froze (Brad caught "All
# 213 recipes" at 513). Now: idempotent regex on ANY number in those phrases, PLUS the counts are
# wrapped in <span class="tc-rc"> markers that the site-wide head script live-updates from the feed's
# recipe_count - so the page is right even between rebuilds.
$rcSpan = '<span class="tc-rc">' + $total + '</span>'
$html=$html -replace '(?:<span class="tc-rc">)?\d+(?:</span>)?( high-protein meal prep dinners\.)', ($rcSpan + '$1')
$html=$html -replace 'All (?:<span class="tc-rc">)?\d+(?:</span>)?( recipes with full instructions)', ('All ' + $rcSpan + '$1')
$html=$html -replace '(?:<span class="tc-rc">)?\d+(?:</span>)?( high-protein dinners, macros from real)', ($rcSpan + '$1')
$html=$html -replace 'Search \d+ dinners:', ("Search $total dinners:")
# "14 servings" left every card, so the library intro has to say it once for the whole page
$html=$html -replace '(Sorted cheapest first\.)( Every card shows real macros)', '$1 Every batch makes 14 servings.$2'
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

# 7) members-only recipe-suggestion form (idempotent; inserted UP TOP, just above the filter
#    bar / grid so members see it without scrolling past all the cards)
$formSrc=[IO.File]::ReadAllText((Join-Path $root 'recipe-request-form.html'),[Text.Encoding]::UTF8).Trim()
$plannerCta='<div style="margin:2.8rem 0 0;padding:20px 22px;background:#16263f;border-radius:16px;color:#fff"><span style="display:inline-block;background:#e2a43c;color:#16263f;font-weight:800;font-size:1.1rem;letter-spacing:.08em;border-radius:999px;padding:3px 12px;margin-bottom:8px">NEW &middot; MEMBER TOOL</span><h3 style="color:#fff;font-size:2rem;margin:.2rem 0 .5rem">Build your meal plan</h3><p style="margin:0 0 1.2rem;font-size:1.45rem;line-height:1.5;color:#c9d2de">Pick your dates, your household size, and your recipes. Get a cook night calendar, one combined grocery list, and live cheapest prices at Omaha stores.</p><a href="/meal-plan-builder/" style="display:inline-block;background:#e2a43c;color:#16263f;font-weight:800;padding:10px 22px;border-radius:999px;text-decoration:none;font-size:1.4rem">Open the Meal Plan Builder &rarr;</a></div>'
$formBlock='<!--RECIPE-SUGGEST-START-->'+$plannerCta+'<div class="mpr-suggest" style="margin:2.8rem 0">'+$formSrc+'</div><!--RECIPE-SUGGEST-END-->'
$rs='<!--RECIPE-SUGGEST-START-->'; $re='<!--RECIPE-SUGGEST-END-->'
$rsi=$html.IndexOf($rs)
if($rsi -ge 0){ $ree=$html.IndexOf($re,$rsi)+$re.Length; $html=$html.Substring(0,$rsi)+$formBlock+$html.Substring($ree) }
else {
  $ai=$html.IndexOf('<!--TC-HUB-LEAD-START-->'); if($ai -lt 0){ $ai=$html.IndexOf('<!--TC-HUB-FILTERS-START-->') }
  if($ai -lt 0){ throw 'no anchor found for the recipe-suggest insert' }
  $html=$html.Substring(0,$ai)+$formBlock+$html.Substring($ai)
}

# ---------------------------------------------------------------------------------------------------
# guards
# ---------------------------------------------------------------------------------------------------
if($html -notmatch [regex]::Escape('id="smprrf-form"')){ throw 'recipe-suggest form missing after splice' }
if(([regex]::Matches($html,'<!--RECIPE-SUGGEST-START-->')).Count -ne 1){ throw 'recipe-suggest markers not unique' }
foreach($mk in @('TC-HUB-CSS','TC-HUB-FILTERS','TC-HUB-JS')){
  if(([regex]::Matches($html,'<!--' + $mk + '-START-->')).Count -ne 1){ throw "$mk markers not unique" }
  if(([regex]::Matches($html,'<!--' + $mk + '-END-->')).Count -ne 1){ throw "$mk end markers not unique" }
}
$nCards=([regex]::Matches($html,'<a class="mpr-card"')).Count
$railN=@($freeRows).Count
if($nCards -ne ($total + $railN)){ throw "card count $nCards != $total grid + $railN rail" }
if($counts.chicken+$counts.pork+$counts.beef+$counts.turkey -ne $total){ throw 'counts do not sum to total' }
if($html -match '113 high-protein'){ throw 'stale 113 copy remains' }
if($html -match '<div class="mpr-card"'){ throw 'legacy div-shaped card survived the splice (the -Validate regex and this guard must agree)' }
# THE FRESHNESS FIXTURE: this page does not rebuild daily, so a build-time "this morning" would be a lie
# most days. Only the client-side upgrade, gated on the feed's own timestamp, may ever say it.
foreach($m in [regex]::Matches($html,'checked this morning')){
  $ctx=$html.Substring([math]::Max(0,$m.Index-260),[math]::Min(260,$m.Index))
  if($ctx -notmatch 'fresh\.textContent'){ throw 'a build-time "checked this morning" literal reached the hub (non-daily surface)' }
}
if($html -notmatch 'checked ' ){ throw 'kitchen ticker lost its build-time date stamp' }
$navyBad = Test-TcNavyAdjacency -Html $html
if(@($navyBad).Count){ throw ('navy-band rule broken on the hub: ' + ($navyBad -join ' | ')) }
foreach($mk in @('<!--SMP-TOP5-->','<!--/SMP-TOP5-->','mp2-hero','mp2-offer','mpr-cta','mpr-empty','mpr-fbtns')){ if($html -notmatch [regex]::Escape($mk)){ throw "lost section: $mk" } }
# the Ads landing page's own contract: the H1/hero copy and the conversion-critical top of the page
foreach($mk in @('Dinner for $2 to $3 a plate','id="mp2-free"')){ if($html -notmatch [regex]::Escape($mk)){ throw "Ads landing hero changed: $mk" } }
if($html.Length -lt $orig.Length){ Write-Warning "new html shorter than orig ($($html.Length) < $($orig.Length))" }
$html | Set-Content (Join-Path $scratch 'hub-new.html') -Encoding UTF8
"spliced OK: cards=$nCards (grid $total + rail $railN)  len $($orig.Length) -> $($html.Length)  written hub-new.html"

if($Publish){
  $lexObj=@{root=[ordered]@{children=@([ordered]@{type='html';version=1;html=$html});direction=$null;format='';indent=0;type='root';version=1}}
  $lex=ConvertTo-Json $lexObj -Depth 12 -Compress
  $body=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json @{pages=@(@{lexical=$lex;updated_at=$page.updated_at})} -Depth 6))
  $jwt=New-GhostJWT
  Invoke-GhostApi -Uri "$apiUrl/ghost/api/admin/pages/$($page.id)/" -Method Put -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0';'Content-Type'='application/json'} -Body $body | Out-Null
  Start-Sleep -Seconds 2
  $pub=(Invoke-WebRequest -Uri 'https://www.thriftycrew.com/meal-prep-recipes/' -UseBasicParsing -TimeoutSec 30).Content
  $liveCards=([regex]::Matches($pub,'<a class="mpr-card"')).Count
  $hasCount=($pub -match "$total high-protein meal prep dinners")
  $hasFilters=($pub -match 'id="mpr-sort"')
  $hasScript=($pub -match 'mpr-tonight-out')
  "PUBLISHED. live cards=$liveCards  copy-updated=$hasCount  sort-live=$hasFilters  script-live=$hasScript"
  if(-not $hasScript){ Write-Warning 'the hub script did not survive the PUT - check that the page is still a lexical html card (?source=html strips scripts)' }
}
