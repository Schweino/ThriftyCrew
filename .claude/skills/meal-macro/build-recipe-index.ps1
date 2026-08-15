<#
  build-recipe-index.ps1  -  Builds a public PAGE /meal-prep-recipes/ from recipes-db.json.
  One card per recipe: name, cuisine, servings, per-serving macros, cost/serving, link to the (paid) recipe.
  Public index = SEO + conversion (shows non-members the depth of the meal-prep library). Upserts by slug.
#>
$ErrorActionPreference='Stop'
. "C:\Codex\ThriftyCrew\.claude\skills\lesson\ghost-config.ps1"
function New-GhostJWT { param($key)
  $p=$key -split ':'; $id=$p[0]; $secretHex=$p[1]
  $sb=New-Object byte[] ($secretHex.Length/2)
  for($i=0;$i -lt $sb.Length;$i++){ $sb[$i]=[Convert]::ToByte($secretHex.Substring($i*2,2),16) }
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $h='{"alg":"HS256","typ":"JWT","kid":"'+$id+'"}'; $pl='{"iat":'+$now+',"exp":'+($now+300)+',"aud":"/admin/"}'
  $b64={param($b)[Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_')}
  $si=(& $b64 ([Text.Encoding]::UTF8.GetBytes($h)))+'.'+(& $b64 ([Text.Encoding]::UTF8.GetBytes($pl)))
  $hm=New-Object System.Security.Cryptography.HMACSHA256 (,$sb); return $si+'.'+(& $b64 ($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes($si))))
}
function HtmlEnc { param($s) return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;') }

$db=(Get-Content "C:\Codex\ThriftyCrew\meal-prep\recipes-db.json" -Raw | ConvertFrom-Json).recipes
$sorted = $db | Sort-Object { [double]$_.cost_per_serving }

# derive the MAIN protein per recipe = the meat ingredient with the most grams (so crack chicken w/ bacon = chicken, etc.)
$meatKw = [ordered]@{ chicken=@('chicken'); turkey=@('turkey'); pork=@('pork','sausage','carnitas'); beef=@('beef','chuck','flank','sirloin') }
function ProteinOf($r){
  $best=''; $bestG=-1.0
  foreach($ing in $r.ingredients){
    $lc=([string]$ing.item).ToLower(); $g=[double]$ing.grams
    foreach($p in $meatKw.Keys){ foreach($kw in $meatKw[$p]){ if($lc -match $kw -and $g -gt $bestG){ $bestG=$g; $best=[string]$p } } }
  }
  if($best){ return $best } else { return 'other' }
}
$protoOf=@{}; $protoCount=[ordered]@{chicken=0;pork=0;beef=0;turkey=0}
foreach($r in $sorted){ $pt=ProteinOf $r; $protoOf[[string]$r.slug]=$pt; if($protoCount.Contains($pt)){ $protoCount[$pt]++ } }
$protoLabel=@{chicken='Chicken';pork='Pork';beef='Beef';turkey='Turkey'}

$style=@'
<style>
.mpr-lead{font-size:1.5rem;line-height:1.6;color:#334155;margin:0 0 2rem}
.mpr-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:1.3rem}
.mpr-card{background:#fff;border:1px solid #e2e8f0;border-radius:14px;padding:1.3rem 1.4rem;display:flex;flex-direction:column}
.mpr-card h3{font-size:1.55rem;color:#16263F;margin:0 0 .2rem;line-height:1.25}
.mpr-meta{font-size:1.15rem;color:#94a3b8;margin-bottom:.9rem}
.mpr-macros{display:flex;gap:.4rem;flex-wrap:wrap;margin-bottom:1rem}
.mpr-b{border-radius:8px;padding:.4rem .6rem;text-align:center;flex:1;min-width:56px}
.mpr-b .n{font-size:1.5rem;font-weight:800;line-height:1}
.mpr-b .l{font-size:1rem;text-transform:uppercase;letter-spacing:.03em;opacity:.8}
.mpr-cal{background:#eef2f7;color:#16263F}.mpr-pro{background:#e6f4ec;color:#1f6f4a}
.mpr-carb{background:#fdf3e3;color:#9a6a1a}.mpr-fat{background:#f6eef0;color:#8a3a4a}
.mpr-cost{margin-top:auto;display:flex;align-items:baseline;justify-content:space-between;border-top:1px dashed #e2e8f0;padding-top:.9rem}
.mpr-cost .c{font-size:2rem;font-weight:800;color:#2f7d5b}
.mpr-cost .c span{font-size:1.15rem;font-weight:500;color:#94a3b8}
.mpr-cost a{font-size:1.3rem;font-weight:700;color:#1E3A5F;text-decoration:none}
.mpr-cost a:hover{text-decoration:underline}
.mpr-cta{margin-top:2.2rem;background:#16263F;border-radius:14px;padding:1.8rem 1.6rem;text-align:center}
.mpr-cta p{color:#F6F1E7;font-size:1.6rem;margin:0 0 1rem;line-height:1.5}
.mpr-cta a{display:inline-block;background:#E2A43C;color:#16263F;font-weight:800;font-size:1.55rem;text-decoration:none;padding:.8rem 2rem;border-radius:9px}
.mpr-why{display:flex;align-items:center;gap:1rem;background:#fdf7ec;border:1px solid #e9d8b8;border-left:5px solid #E2A43C;border-radius:12px;padding:1.1rem 1.4rem;text-decoration:none!important;margin:0 0 1.6rem;transition:background .12s,box-shadow .12s}
.mpr-why:hover{background:#fbf1dd;box-shadow:0 6px 16px rgba(226,164,60,.15)}
.mpr-why,.mpr-why:hover,.mpr-why strong,.mpr-why span{text-decoration:none!important}
.mpr-why:hover .mpr-why-txt strong{text-decoration:underline!important;text-underline-offset:2px}
.mpr-why-ic{font-size:2rem;line-height:1}
.mpr-why-txt{flex:1}
.mpr-why-txt strong{display:block;font-size:1.45rem;color:#16263F}
.mpr-why-txt span{font-size:1.2rem;color:#64748b}
.mpr-why-arrow{font-size:1.8rem;color:#E2A43C;font-weight:800;line-height:1}
.mpr-filters{margin:0 0 1.7rem;padding:1.2rem 1.35rem;background:#f8fafc;border:1px solid #e2e8f0;border-radius:14px}
.mpr-frow{display:flex;align-items:center;gap:1rem;flex-wrap:wrap;margin-bottom:1rem}
.mpr-frow:last-of-type{margin-bottom:0}
.mpr-flabel{font-size:1.05rem;font-weight:700;text-transform:uppercase;letter-spacing:.05em;color:#64748b;min-width:78px}
.mpr-fbtns{display:flex;gap:.5rem;flex-wrap:wrap}
.mpr-fb{border:1px solid #cbd5e1;background:#fff;color:#475569;border-radius:999px;padding:.5rem 1.15rem;font-size:1.2rem;font-weight:600;cursor:pointer;font-family:inherit;transition:.12s}
.mpr-fb:hover{border-color:#1E3A5F;color:#16263F}
.mpr-fb.is-on{background:#16263F;border-color:#16263F;color:#fff}
.mpr-fn{opacity:.55;font-weight:500;margin-left:.2rem}
.mpr-fb.is-on .mpr-fn{opacity:.85}
.mpr-cal-ctl{display:flex;align-items:center;gap:.6rem;flex-wrap:wrap}
.mpr-cal-ctl input{width:96px;font-size:1.2rem;padding:.5rem .7rem;border:1px solid #cbd5e1;border-radius:9px;font-family:inherit;color:#16263F;background:#fff}
.mpr-cal-ctl input:focus{outline:none;border-color:#E2A43C;box-shadow:0 0 0 3px rgba(226,164,60,.15)}
.mpr-cal-ctl .sep{color:#94a3b8;font-size:1.15rem}
.mpr-cal-ctl .unit{color:#94a3b8;font-size:1.05rem}
.mpr-clear{border:none;background:none;color:#1E3A5F;font-weight:700;font-size:1.1rem;cursor:pointer;text-decoration:underline;font-family:inherit;padding:.3rem}
.mpr-count{font-size:1.15rem;color:#64748b;font-weight:600;margin-top:.2rem}
.mpr-empty{display:none;font-size:1.35rem;color:#64748b;text-align:center;padding:2.5rem 1rem}
/* --- 2026-07-11 landing redesign (hero / free taste / steps / offer) --- */
.mp2-hero{background:#16263F;border-radius:16px;padding:2.6rem 2.2rem;margin:0 0 2rem;text-align:center}
.mp2-hero h2{color:#F6F1E7;font-size:2.6rem;margin:0 0 1rem;line-height:1.25}
.mp2-hero p{color:#cfd6e2;font-size:1.5rem;line-height:1.6;margin:0 auto 1.6rem;max-width:62rem}
.mp2-ctas{display:flex;gap:1rem;justify-content:center;flex-wrap:wrap;margin:0 0 1.2rem}
.mp2-btn-gold{display:inline-block;background:#E2A43C;color:#16263F!important;font-weight:800;font-size:1.5rem;text-decoration:none!important;padding:1rem 2.2rem;border-radius:10px}
.mp2-btn-ghost{display:inline-block;background:transparent;color:#F6F1E7!important;border:1.5px solid #5a6a85;font-weight:700;font-size:1.5rem;text-decoration:none!important;padding:1rem 2rem;border-radius:10px}
.mp2-trust{color:#8fa0b8!important;font-size:1.2rem!important;margin:0!important}
.mp2-h{font-size:2rem;color:#16263F;margin:2.8rem 0 1.2rem}
.mp2-t5ph{background:#fdf8ec;border:1px solid #eee3c8;border-radius:12px;padding:1.4rem;font-size:1.35rem;color:#3a4658;margin:0 0 .4rem}
.mp2-freegrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:1.2rem}
.mp2-fcard{display:flex;flex-direction:column;gap:.5rem;background:#fff;border:1px solid #e2e8f0;border-top:3px solid #E2A43C;border-radius:12px;padding:1.4rem;text-decoration:none!important;transition:transform .12s,box-shadow .12s}
.mp2-fcard:hover{transform:translateY(-2px);box-shadow:0 8px 22px rgba(22,38,63,.10)}
.mp2-fcard,.mp2-fcard *{text-decoration:none!important}
.mp2-fbadge{align-self:flex-start;background:#e6f4ec;color:#1f6f4a;font-size:1.05rem;font-weight:800;letter-spacing:.04em;text-transform:uppercase;padding:.25rem .8rem;border-radius:999px}
.mp2-fcard strong{font-size:1.55rem;color:#16263F;line-height:1.3}
.mp2-fcard .d{font-size:1.25rem;color:#64748b;line-height:1.5}
.mp2-steps{list-style:none;counter-reset:mp2;margin:0;padding:0;display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:1.2rem}
.mp2-steps li{counter-increment:mp2;background:#f8fafc;border:1px solid #e2e8f0;border-radius:12px;padding:3.4rem 1.4rem 1.3rem;font-size:1.3rem;color:#475569;line-height:1.55;position:relative}
.mp2-steps li::before{content:counter(mp2);position:absolute;top:1.1rem;left:1.4rem;width:2.2rem;height:2.2rem;border-radius:50%;background:#E2A43C;color:#16263F;font-weight:800;font-size:1.3rem;display:flex;align-items:center;justify-content:center}
.mp2-steps b{color:#16263F}
.mp2-offer{background:#16263F;border-radius:16px;padding:2.2rem;margin:2.8rem 0;text-align:center}
.mp2-offer h2{color:#F6F1E7;font-size:2.2rem;margin:0 0 1.2rem}
.mp2-offer ul{list-style:none;margin:0 auto 1.6rem;padding:0;max-width:46rem;text-align:left}
.mp2-offer li{color:#cfd6e2;font-size:1.4rem;padding:.45rem 0 .45rem 2.4rem;position:relative}
.mp2-offer li::before{content:"\2713";position:absolute;left:.4rem;color:#E2A43C;font-weight:800}
.mp2-note{color:#8fa0b8;font-size:1.2rem;margin:1rem 0 0}
.mp2-libline{font-size:1.35rem;color:#64748b;line-height:1.6;margin:0 0 1.6rem}
@media(max-width:560px){.mp2-hero h2{font-size:2.1rem}.mp2-hero{padding:2rem 1.4rem}}
</style>
'@

$sb=New-Object System.Text.StringBuilder
[void]$sb.Append($style)

# ---- 1) HERO: the promise, in the searcher's own words ----
[void]$sb.Append('<div class="mp2-hero"><h2>Dinner for $2 to $3 a plate, priced from real stores</h2><p>' + $sorted.Count + ' high-protein meal prep dinners. The macros come from actual nutrition labels. The costs come from six Omaha grocery stores we price-check every morning. Cook once, eat all week.</p><div class="mp2-ctas"><a class="mp2-btn-gold" href="/#/portal/signup">Get every recipe for $1 a month</a><a class="mp2-btn-ghost" href="#mp2-free">Try one free first</a></div><p class="mp2-trust">$1 a month or $10 a year. No trial games. Cancel in two clicks.</p></div>')

# ---- 2) TOP-5 SLOT: top5-weekly.ps1 replaces everything between these markers daily (in place) ----
[void]$sb.Append('<!--SMP-TOP5--><div class="mp2-t5ph"><p style="margin:0"><b>This week&#39;s five cheapest dinners</b> get recomputed from live store prices every morning and land right here. Check back in a moment.</p></div><!--/SMP-TOP5-->')

# ---- 3) FREE TASTE: win them once before the dollar ----
[void]$sb.Append('<h2 class="mp2-h" id="mp2-free">Start free. No card, no catch</h2><div class="mp2-freegrid">')
[void]$sb.Append('<a class="mp2-fcard" href="/free-chicken-alfredo/"><span class="mp2-fbadge">Free</span><strong>Chicken Alfredo, the full recipe</strong><span class="d">A real member recipe, open to everyone. Fourteen servings at about $2.40 each.</span></a>')
[void]$sb.Append('<a class="mp2-fcard" href="/whats-for-dinner-tonight/"><span class="mp2-fbadge">Free</span><strong>What&#39;s for Dinner Tonight?</strong><span class="d">Tap what&#39;s in your kitchen and get the cheapest dinner you can make tonight, live-priced.</span></a>')
[void]$sb.Append('<a class="mp2-fcard" href="/why-meal-prep-and-the-essentials/"><span class="mp2-fbadge">Free</span><strong>Why meal prep, and what you need</strong><span class="d">The case for cooking once and eating all week, plus the starter gear that actually matters.</span></a>')
[void]$sb.Append('</div>')

# ---- 4) HOW IT WORKS: three steps, no fluff ----
[void]$sb.Append('<h2 class="mp2-h">How members use this</h2><ol class="mp2-steps">')
[void]$sb.Append('<li><b>Pick two or three dinners</b> for the week. Filter by protein, calories, or this week&#39;s prices.</li>')
[void]$sb.Append('<li><b>Shop one grocery list.</b> Every recipe comes with its list, and our price board shows the cheapest Omaha store for the big items.</li>')
[void]$sb.Append('<li><b>Cook once.</b> Fourteen portioned servings per batch. Dinner is handled, and lunch usually is too.</li>')
[void]$sb.Append('</ol>')

# ---- 5) OFFER: the actual ask ----
[void]$sb.Append('<div class="mp2-offer"><h2>Everything, for a dollar</h2><ul><li>All ' + $sorted.Count + ' recipes with full instructions and grocery lists</li><li>Live weekly pricing on every recipe</li><li>Every member tool on the site</li><li>New recipes as they drop</li><li>Cancel anytime, in two clicks</li></ul><a class="mp2-btn-gold" href="/#/portal/signup">Join the Crew for $1 &rarr;</a><p class="mp2-note">Rather pay once? $10 a year. That is the only other option.</p></div>')

# ---- 6) THE LIBRARY ----
[void]$sb.Append('<h2 class="mp2-h">The full library</h2>')
[void]$sb.Append('<p class="mp2-libline">Sorted cheapest first. Every card shows real macros and an honest cost per serving. Full recipes open for members; the <a href="/free-chicken-alfredo/">Chicken Alfredo</a> is free if you want to test-drive one first.</p>')
# filter bar: protein type + calorie range
[void]$sb.Append('<div class="mpr-filters">')
[void]$sb.Append('<div class="mpr-frow"><span class="mpr-flabel">Protein</span><div class="mpr-fbtns">')
[void]$sb.Append('<button class="mpr-fb is-on" data-p="all">All</button>')
foreach($p in @('chicken','pork','beef','turkey')){ [void]$sb.Append('<button class="mpr-fb" data-p="'+$p+'">'+$protoLabel[$p]+' <span class="mpr-fn">'+$protoCount[$p]+'</span></button>') }
[void]$sb.Append('</div></div>')
[void]$sb.Append('<div class="mpr-frow"><span class="mpr-flabel">Calories</span><div class="mpr-cal-ctl"><input type="number" id="mpr-cmin" placeholder="min" min="0" step="10" inputmode="numeric" aria-label="Minimum calories"><span class="sep">to</span><input type="number" id="mpr-cmax" placeholder="max" min="0" step="10" inputmode="numeric" aria-label="Maximum calories"><span class="unit">cal / serving</span><button class="mpr-clear" id="mpr-clear" type="button">Reset</button></div></div>')
[void]$sb.Append('<div class="mpr-count" id="mpr-count"></div>')
[void]$sb.Append('</div>')
[void]$sb.Append('<div class="mpr-grid">')
foreach($r in $sorted){
  $ps=$r.per_serving
  [void]$sb.Append('<div class="mpr-card" data-protein="'+$protoOf[[string]$r.slug]+'" data-cal="'+[int]$ps.calories+'">')
  [void]$sb.Append('<h3>'+(HtmlEnc $r.name)+'</h3>')
  [void]$sb.Append('<div class="mpr-meta">'+(HtmlEnc $r.cuisine)+' &middot; '+$r.servings+' servings</div>')
  [void]$sb.Append('<div class="mpr-macros">')
  [void]$sb.Append('<div class="mpr-b mpr-cal"><div class="n">'+[int]$ps.calories+'</div><div class="l">cal</div></div>')
  [void]$sb.Append('<div class="mpr-b mpr-pro"><div class="n">'+[int]$ps.protein_g+'g</div><div class="l">protein</div></div>')
  [void]$sb.Append('<div class="mpr-b mpr-carb"><div class="n">'+[int]$ps.carbs_g+'g</div><div class="l">carbs</div></div>')
  [void]$sb.Append('<div class="mpr-b mpr-fat"><div class="n">'+[int]$ps.fat_g+'g</div><div class="l">fat</div></div>')
  [void]$sb.Append('</div>')
  $cost='{0:N2}' -f [double]$r.cost_per_serving
  [void]$sb.Append('<div class="mpr-cost"><div class="c">$'+$cost+' <span>/ serving</span></div><a href="/'+$r.slug+'/">See it &rarr;</a></div>')
  [void]$sb.Append('</div>')
}
[void]$sb.Append('</div>')
[void]$sb.Append('<div class="mpr-empty" id="mpr-empty">No recipes match those filters. Try widening the calorie range or choosing a different protein.</div>')
[void]$sb.Append('<div class="mpr-cta"><p>'+$sorted.Count+' high-protein dinners, macros from real labels, costs from real stores. Full recipes and grocery lists are members only.</p><a href="/#/portal/signup">Get every recipe for $1 a month</a></div>')
[void]$sb.Append(@'
<script>
(function(){
  var cards=[].slice.call(document.querySelectorAll(".mpr-card"));
  var pbtns=[].slice.call(document.querySelectorAll(".mpr-fb"));
  var cmin=document.getElementById("mpr-cmin"), cmax=document.getElementById("mpr-cmax");
  var count=document.getElementById("mpr-count"), clear=document.getElementById("mpr-clear"), empty=document.getElementById("mpr-empty");
  var curP="all";
  function apply(){
    var lo=parseInt(cmin.value,10), hi=parseInt(cmax.value,10);
    if(isNaN(lo))lo=0; if(isNaN(hi))hi=999999;
    var shown=0;
    cards.forEach(function(c){
      var okP = curP==="all" || c.getAttribute("data-protein")===curP;
      var cal=parseInt(c.getAttribute("data-cal"),10);
      var okC = cal>=lo && cal<=hi;
      var vis = okP && okC;
      c.style.display = vis ? "" : "none";
      if(vis) shown++;
    });
    count.textContent = "Showing "+shown+" recipe"+(shown===1?"":"s");
    if(empty) empty.style.display = shown ? "none" : "block";
  }
  pbtns.forEach(function(b){ b.addEventListener("click",function(){ pbtns.forEach(function(x){x.classList.remove("is-on");}); b.classList.add("is-on"); curP=b.getAttribute("data-p"); apply(); }); });
  cmin.addEventListener("input",apply); cmax.addEventListener("input",apply);
  clear.addEventListener("click",function(){ cmin.value=""; cmax.value=""; pbtns.forEach(function(x){x.classList.remove("is-on");}); pbtns[0].classList.add("is-on"); curP="all"; apply(); });
  apply();
})();
</script>
'@)
$html=$sb.ToString()

$jwt=New-GhostJWT $adminKey
$slug='meal-prep-recipes'
$existing=$null
try{ $existing=(Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/pages/slug/$slug/?fields=id,updated_at" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}).pages[0] }catch{}
$lexObj=@{root=[ordered]@{children=@([ordered]@{type='html';version=1;html=[string]$html});direction=$null;format='';indent=0;type='root';version=1}}
$lex=ConvertTo-Json $lexObj -Depth 12 -Compress
$mt='Cheap High-Protein Meal Prep Recipes | Thrifty Crew'
$md='113 high-protein meal prep dinners with real macros and honest cost per serving, priced from six Omaha stores checked daily. Most land at $2 to $3 a plate. Full recipes for $1 a month.'
$obj=[ordered]@{title='Meal Prep Recipes';slug=$slug;lexical=$lex;status='published';visibility='public';custom_excerpt='Every high-protein, budget meal-prep recipe with macros and cost per serving on one page.';meta_title=$mt;meta_description=$md;og_title=$mt;og_description=$md;twitter_title=$mt;twitter_description=$md;show_title_and_feature_image=$true}
if($existing){ $obj.updated_at=$existing.updated_at;$method='Put';$uri="$apiUrl/ghost/api/admin/pages/$($existing.id)/" } else { $method='Post';$uri="$apiUrl/ghost/api/admin/pages/" }
$bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json @{pages=@($obj)} -Depth 14))
$jwt=New-GhostJWT $adminKey
$r=Invoke-RestMethod -Uri $uri -Method $method -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -ContentType 'application/json' -Body $bytes -TimeoutSec 30
Write-Output ("RECIPE INDEX: "+$r.pages[0].url+"  ("+$sorted.Count+" recipes)")
