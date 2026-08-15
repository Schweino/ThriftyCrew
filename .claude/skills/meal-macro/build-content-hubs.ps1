<#
  build-content-hubs.ps1  -  Builds two public pillar PAGES from live Ghost data:
    /money-glossary/  (all Glossary terms)   -> filterable directory (search + topic chips + card grid)
    /money-hacks/     (all Money Hacks posts) -> filterable directory (search + topic chips + card grid)
  Both share one "Build-Directory" template. Upserts each page by slug (safe to re-run).
  NOTE (PS 5.1 reads .ps1 as ANSI): keep this file ASCII. Emoji are HTML numeric entities (&#NNNNN;) so they survive.
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
function Get-PostsByTag { param($tagSlug)
  $jwt=New-GhostJWT $adminKey; $all=@(); $page=1
  do {
    $u="$apiUrl/ghost/api/admin/posts/?filter=tag:$tagSlug%2Bstatus:published&limit=100&page=$page&fields=title,slug,custom_excerpt"
    $r=Invoke-RestMethod -Uri $u -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}
    $all += $r.posts; $page++
  } while ($r.posts.Count -eq 100)
  return $all
}

# ---------- SHARED FILTERABLE-DIRECTORY TEMPLATE ----------
$TPL = @'
<style>
.mh{max-width:1040px;margin:0 auto;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;color:#16263F}
.mh *{box-sizing:border-box}
.mh-hero{background:linear-gradient(135deg,#1E3A5F 0%,#16263F 100%);border-radius:18px;padding:2.6rem 1.5rem;text-align:center;margin-bottom:1.4rem}
.mh-hero h1{font-family:Georgia,"Times New Roman",serif;font-size:2.8rem;color:#F6F1E7;margin:0 0 .6rem;font-weight:600;line-height:1.12}
.mh-hero p{color:#c7d2e1;font-size:1.45rem;max-width:660px;margin:0 auto;line-height:1.55}
.mh-hero .mh-gold{color:#E2A43C;font-weight:700}
.mh-bar{position:sticky;top:0;z-index:6;background:rgba(248,250,252,.97);backdrop-filter:blur(6px);padding:1rem 0 .9rem;margin-bottom:.2rem;border-bottom:1px solid #e8edf3}
.mh-search{position:relative;max-width:560px;margin:0 auto .9rem}
.mh-search input{width:100%;font-size:1.5rem;padding:.85rem 1rem .85rem 3rem;border:2px solid #cbd5e1;border-radius:12px;background:#fff;color:#16263F}
.mh-search input:focus{outline:none;border-color:#E2A43C;box-shadow:0 0 0 3px rgba(226,164,60,.15)}
.mh-search svg{position:absolute;left:13px;top:50%;transform:translateY(-50%);width:19px;height:19px;fill:none;stroke:#94a3b8;stroke-width:2}
.mh-chips{display:flex;flex-wrap:wrap;gap:.5rem;justify-content:center}
.mh-chip{cursor:pointer;font-size:1.25rem;font-weight:600;padding:.45rem .95rem;border-radius:999px;border:1.5px solid #d7dee7;background:#fff;color:#334155;white-space:nowrap;transition:all .12s;user-select:none}
.mh-chip:hover{border-color:#1E3A5F}
.mh-chip.active{background:#16263F;border-color:#16263F;color:#fff}
.mh-chip .n{opacity:.55;font-weight:400;margin-left:.2rem}
.mh-chip.active .n{opacity:.8}
.mh-count{text-align:center;font-size:1.25rem;color:#94a3b8;margin:1rem 0 1.3rem}
.mh-sec{margin:0 0 .4rem}
.mh-sec-h{display:flex;align-items:center;justify-content:space-between;gap:.5rem;font-size:1.6rem;font-weight:800;color:#16263F;margin:0;padding:.9rem .2rem;border-bottom:2px solid #E2A43C;cursor:pointer;user-select:none}
.mh-sec-h:hover{color:#1E3A5F}
.mh-sec-hl{display:flex;align-items:center;gap:.5rem;flex-wrap:wrap}
.mh-sec-h .n{font-size:1.15rem;font-weight:400;color:#94a3b8}
.mh-chev{font-size:1.05rem;color:#c9a24a;transition:transform .18s;flex-shrink:0}
.mh-sec.open .mh-chev{transform:rotate(90deg)}
.mh-sec .mh-grid{display:none;margin:1rem 0 1.6rem}
.mh-sec.open .mh-grid{display:grid}
.mh-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:1rem}
.mh-card{display:block;background:#fff;border:1px solid #e2e8f0;border-radius:13px;padding:1.1rem 1.25rem;text-decoration:none;transition:transform .12s,box-shadow .12s,border-color .12s}
.mh-card:hover{transform:translateY(-2px);box-shadow:0 8px 22px rgba(22,38,63,.1);border-color:#c9b071}
.mh-card .mh-cat{display:inline-block;font-size:1.02rem;font-weight:600;color:#b07d1f;background:#fdf3e0;padding:.15rem .55rem;border-radius:6px;margin-bottom:.55rem}
.mh-card .mh-t{font-size:1.4rem;font-weight:700;color:#1E3A5F;line-height:1.3;margin:0 0 .4rem}
.mh-card .mh-e{font-size:1.2rem;color:#64748b;line-height:1.5;margin:0}
.mh-empty{text-align:center;padding:3rem 1rem;color:#94a3b8;font-size:1.45rem}
.mh-cta{margin-top:2.2rem;background:#16263F;border-radius:16px;padding:1.9rem 1.6rem;text-align:center}
.mh-cta p{color:#F6F1E7;font-size:1.55rem;margin:0 0 1.1rem;line-height:1.5}
.mh-cta a{display:inline-block;background:#E2A43C;color:#16263F;font-weight:800;font-size:1.5rem;text-decoration:none;padding:.8rem 2rem;border-radius:10px}
@media(max-width:600px){.mh-hero h1{font-size:2.1rem}.mh-grid{grid-template-columns:1fr}}
</style>
<div class="mh">
  <div class="mh-hero"><h1>__TITLE__</h1><p>__SUB__</p></div>
  <div class="mh-bar">
    <div class="mh-search">
      <svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line></svg>
      <input id="mhSearch" type="search" placeholder="__PLACEHOLDER__" autocomplete="off">
    </div>
    <div class="mh-chips" id="mhChips"></div>
  </div>
  <div class="mh-count" id="mhCount"></div>
  <div id="mhResults"></div>
  <div class="mh-cta"><p>__CTA__</p><a href="/#/portal/signup">__CTABTN__</a></div>
</div>
<script>
(function(){
  var ITEMS=__DATA__; var CATORDER=__CATORDER__; var ICONS=__ICONS__; var NOUN="__NOUN__";
  var counts={}; ITEMS.forEach(function(h){counts[h.c]=(counts[h.c]||0)+1;});
  var searchEl=document.getElementById("mhSearch"), chipsEl=document.getElementById("mhChips"), resultsEl=document.getElementById("mhResults"), countEl=document.getElementById("mhCount");
  var active="all", term="";
  function esc(s){return (s||"").replace(/[&<>"]/g,function(c){return {"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;"}[c];});}
  function ic(c){return ICONS[c]||"&#128161;";}
  function renderChips(){
    var html='<span class="mh-chip'+(active==="all"?" active":"")+'" data-c="all">All <span class="n">'+ITEMS.length+'</span></span>';
    CATORDER.forEach(function(c){ if(!counts[c])return; html+='<span class="mh-chip'+(active===c?" active":"")+'" data-c="'+c+'">'+ic(c)+' '+esc(c)+' <span class="n">'+counts[c]+'</span></span>'; });
    chipsEl.innerHTML=html;
    Array.prototype.forEach.call(chipsEl.querySelectorAll(".mh-chip"),function(ch){ ch.addEventListener("click",function(){ active=ch.getAttribute("data-c"); render(); }); });
  }
  function card(h,showCat){ return '<a class="mh-card" href="/'+h.s+'/">'+(showCat?'<span class="mh-cat">'+ic(h.c)+' '+esc(h.c)+'</span>':'')+'<div class="mh-t">'+esc(h.t)+'</div>'+(h.e?'<div class="mh-e">'+esc(h.e)+'</div>':'')+'</a>'; }
  function render(){
    renderChips();
    var t=term.trim().toLowerCase();
    var matched=ITEMS.filter(function(h){ var okC=(active==="all"||h.c===active); var okT=(!t||h.t.toLowerCase().indexOf(t)>=0||(h.e&&h.e.toLowerCase().indexOf(t)>=0)); return okC&&okT; });
    countEl.textContent=(matched.length===ITEMS.length)?("All "+ITEMS.length+" "+NOUN):("Showing "+matched.length+" "+NOUN.replace(/s$/,"")+(matched.length===1?"":"s"));
    if(!matched.length){ resultsEl.innerHTML='<div class="mh-empty">Nothing matches that search. Try another word, or tap a topic above.</div>'; return; }
    var html="";
    if(active==="all" && !t){
      CATORDER.forEach(function(c){ var items=matched.filter(function(h){return h.c===c;}); if(!items.length)return; html+='<div class="mh-sec"><div class="mh-sec-h" role="button" tabindex="0" aria-expanded="false"><span class="mh-sec-hl">'+ic(c)+' '+esc(c)+' <span class="n">'+items.length+'</span></span><span class="mh-chev">&#9656;</span></div><div class="mh-grid">'+items.map(function(h){return card(h,false);}).join("")+'</div></div>'; });
    } else {
      html='<div class="mh-grid">'+matched.map(function(h){return card(h,active==="all");}).join("")+'</div>';
    }
    resultsEl.innerHTML=html;
    Array.prototype.forEach.call(resultsEl.querySelectorAll(".mh-sec-h"),function(hd){ hd.addEventListener("click",function(){ var sec=hd.parentNode; var op=sec.classList.toggle("open"); hd.setAttribute("aria-expanded",op?"true":"false"); }); hd.addEventListener("keydown",function(e){ if(e.key==="Enter"||e.key===" "){ e.preventDefault(); hd.click(); } }); });
  }
  searchEl.addEventListener("input",function(){ term=searchEl.value; render(); });
  render();
})();
</script>
'@

function Build-Directory { param($items,$catorder,[hashtable]$icons,$title,$sub,$placeholder,$cta,$ctabtn,$noun)
  $dataJson = ConvertTo-Json @($items) -Depth 4
  if($dataJson.TrimStart()[0] -ne '['){ $dataJson = '['+$dataJson+']' }
  $dataJson = $dataJson.Replace('</','<\/')
  $catJson  = ConvertTo-Json @($catorder) -Compress
  $iconJson = ConvertTo-Json $icons -Compress
  $html = $TPL
  $html = $html.Replace('__DATA__',$dataJson).Replace('__CATORDER__',$catJson).Replace('__ICONS__',$iconJson).Replace('__NOUN__',$noun)
  $html = $html.Replace('__TITLE__',$title).Replace('__SUB__',$sub).Replace('__PLACEHOLDER__',$placeholder).Replace('__CTA__',$cta).Replace('__CTABTN__',$ctabtn)
  return $html
}

# ---------- MONEY HACKS ----------
$hackCats = [ordered]@{
 'Meal Prep' = @('meal-prep','meal-plan','freezer','crockpot','instant-pot','sheet-pan','mason-jar','overnight-oats','breakfast-burrito','rotisserie','batch-cooking-chicken','chicken-and-rice','chicken-breast','sunday-meal','count-macros','meal-prep-container','high-protein-breakfast','high-protein-lunch','high-protein-shake','high-fiber','high-volume','keto','low-carb','vegetarian','no-cook','ground-beef','season-meal','freeze-meals','portion-your-meal','best-proteins')
 'Cheap Eats & Grocery' = @('grocery','cheap-dinner','cheap-lunch','budget-breakfast','cheap-healthy','cheap-high-protein','cheap-vegetarian','best-cheap-high-protein','food-waste','pantry','staples','buying-in-bulk','meal-planning-to-save','healthy-meal-prep-snack')
 'Debt & Credit' = @('debt','credit','apr','dispute')
 'Investing & Retirement' = @('invest','401k','roth','ira','index-fund','stock-market','brokerage','rebalance','portfolio','fire','millionaire','net-worth','financial-advisor','financial-plan','wealth','catch-up-on-retirement','when-should-i-start','tax-refund')
 'Earning More' = @('side-hustle','freelanc','ask-for-a-raise','negotiate-your-salary','income-stream','job-loss','student-loan')
 'Bills & Big Costs' = @('electric','utilities','cell-phone','streaming','car-payment','car-insurance','negotiate-any-bill','negotiate-medical','monthly-bills','subscription','cash-back','amazon','pets','prescriptions','renters-insurance','hsa-vs-fsa','avoid-bank-fees','credit-union-vs-bank','online-bank','high-yield-savings-vs-cd','how-many-credit-cards','house','mortgage','renting','lease','new-vs-used','down-payment','baby','wedding','do-i-need-a-will','big-purchases','travel','vacation','recession')
 'Budgeting' = @('budget','cash-envelope','track-your-expenses','stick-to-your-budget','choose-a-budgeting','monthly-money-review','biweekly','irregular-income','couple','automate-your-finances')
 'Saving & Habits' = @('save','no-spend','spending-fast','money-reset','sinking-fund','emergency-fund','money-saving-challenge','frugal','live-below','paycheck-to-paycheck','money-rules','simple-money-saving','how-much-should','how-many-months','extra-1000','set-money-goals','holidays','stop-overspending','stop-impulse','24-hour','things-frugal','false-frugal','teach-your-kids','money-mistakes')
}
$hackIcons = @{ 'Meal Prep'='&#127859;';'Cheap Eats & Grocery'='&#128722;';'Debt & Credit'='&#128179;';'Investing & Retirement'='&#128200;';'Earning More'='&#128188;';'Bills & Big Costs'='&#127974;';'Budgeting'='&#128202;';'Saving & Habits'='&#128055;';'More Guides'='&#128161;' }
$hacks = Get-PostsByTag 'money-hacks'
$hackItems=@()
foreach($p in ($hacks | Sort-Object title)){
  $cat='More Guides'
  foreach($k in $hackCats.Keys){ $hit=$false; foreach($kw in $hackCats[$k]){ if($p.slug -like "*$kw*"){ $cat=$k; $hit=$true; break } }; if($hit){ break } }
  $hackItems += [ordered]@{ t=[string]$p.title; s=[string]$p.slug; e=[string]$p.custom_excerpt; c=$cat }
}
$hc=$hackItems.Count
$hackOrder=@('Meal Prep','Cheap Eats & Grocery','Debt & Credit','Investing & Retirement','Earning More','Bills & Big Costs','Budgeting','Saving & Habits','More Guides')
$hacksHtml = Build-Directory $hackItems $hackOrder $hackIcons 'Money Hacks' ('<span class="mh-gold">'+$hc+' free guides</span> that put real money back in your pocket. Search for what you need, filter by topic, and run the play this weekend.') ("Search $hc guides...") 'These free guides are the warm-up. Members get every lesson, calculator, budget tool, and meal-prep recipe, all stacked into one step-by-step plan.' 'Join for $1 a month' 'guides'

# ---------- GLOSSARY ----------
$glossCats = [ordered]@{
 'Investing'             = @('index-fund','etf','expense-ratio','dividend','capital-gains','bond','mutual-fund','dollar-cost-averaging','asset-allocation','brokerage-account','stock','portfolio','diversification','bull-vs-bear-market','roi','equity','market-cap','ipo','reit','robo-advisor','tax-loss-harvesting','target-date-fund','cost-basis')
 'Retirement Accounts'   = @('401k','roth-ira','traditional-ira','employer-match','compound-interest','vesting','401k-rollover','403b','529-plan','required-minimum-distribution','roth-vs-traditional')
 'Credit & Debt'         = @('credit-score','credit-utilization','apr','minimum-payment','amortization','credit-limit','secured-vs-unsecured-debt','cosigner','balance-transfer','debt-to-income-ratio','hard-vs-soft-inquiry','credit-report','collections','charge-off','grace-period','annual-fee','cash-advance','foreign-transaction-fee','authorized-user','chargeback')
 'Banking & Saving'      = @('apy','high-yield-savings-account','emergency-fund','sinking-fund','certificate-of-deposit','overdraft-fee','direct-deposit','ach-transfer','fdic-insurance','routing-vs-account-number','money-market-account','cd-ladder','wire-transfer','atm-fee','minimum-balance-fee')
 'Home & Housing'        = @('mortgage','down-payment','closing-costs','pmi','refinance','escrow','property-tax','homeowners-insurance','hoa-fees','home-equity')
 'Loans & Borrowing'     = @('origination-fee','prepayment-penalty','fixed-vs-variable-rate','heloc','personal-loan')
 'Insurance & Protection'= @('insurance-premium','insurance-deductible','hsa','term-vs-whole-life','out-of-pocket-maximum','beneficiary','will-vs-trust','power-of-attorney','umbrella-insurance','life-insurance')
 'Taxes & Your Paycheck' = @('gross-vs-net-pay','tax-bracket','standard-deduction','w2-vs-1099','tax-withholding','capital-gains-tax')
 'The Economy'           = @('recession','deflation','purchasing-power','federal-reserve','gdp')
 'Budgeting Basics'      = @('cash-flow','pay-yourself-first','discretionary-spending','windfall','zero-based-budgeting')
 'Work & Income'         = @('salary-vs-hourly','overtime-pay','commission','employee-benefits','severance-pay')
 'Core Money Terms'      = @('net-worth','budget','inflation','principal','liquidity','opportunity-cost','disposable-income','simple-vs-compound-interest','fixed-vs-variable-expenses','sunk-cost')
}
$glossIcons = @{ 'Investing'='&#128200;';'Retirement Accounts'='&#127919;';'Credit & Debt'='&#128179;';'Banking & Saving'='&#127974;';'Home & Housing'='&#127968;';'Loans & Borrowing'='&#128221;';'Insurance & Protection'='&#128737;';'Taxes & Your Paycheck'='&#129534;';'The Economy'='&#127760;';'Budgeting Basics'='&#128203;';'Work & Income'='&#128188;';'Core Money Terms'='&#128273;';'More Terms'='&#128161;' }
$slugToCat=@{}
foreach($k in $glossCats.Keys){ foreach($sl in $glossCats[$k]){ $slugToCat[$sl]=$k } }
$gloss = Get-PostsByTag 'glossary'
$glossItems=@()
foreach($p in ($gloss | Sort-Object title)){
  $cat = if($slugToCat.ContainsKey($p.slug)){ $slugToCat[$p.slug] } else { 'More Terms' }
  $label = ($p.title -replace ',?\s*Explained Simply','').Trim()
  $glossItems += [ordered]@{ t=[string]$label; s=[string]$p.slug; e=[string]$p.custom_excerpt; c=$cat }
}
$gc=$glossItems.Count
$glossOrder=@('Investing','Retirement Accounts','Credit & Debt','Banking & Saving','Home & Housing','Loans & Borrowing','Insurance & Protection','Taxes & Your Paycheck','The Economy','Budgeting Basics','Work & Income','Core Money Terms','More Terms')
$glossHtml = Build-Directory $glossItems $glossOrder $glossIcons 'The Money Glossary' ('<span class="mh-gold">'+$gc+' money terms</span> explained in plain English, each with a real dollar example. Search a word or browse by topic.') ("Search $gc terms...") 'That is just the glossary. Members get every lesson, calculator, budget tool, and meal-prep recipe for a dollar a month.' 'Join for $1 a month' 'terms'
$glossHtml += '<script type="application/ld+json">{"@context":"https://schema.org","@type":"DefinedTermSet","name":"Thrifty Crew Money Glossary","description":"Plain-English definitions of the money terms people actually search, each with a real-dollar example.","url":"https://www.simplemoneyplaybook.com/money-glossary/"}</script>'

# ---------- UPSERT PAGES ----------
function Upsert-Page { param($slug,$title,$html,$excerpt,$metaTitle,$metaDesc)
  $jwt=New-GhostJWT $adminKey; $existing=$null
  try{ $existing=(Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/pages/slug/$slug/?fields=id,updated_at" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}).pages[0] }catch{}
  $lexObj=@{root=[ordered]@{children=@([ordered]@{type='html';version=1;html=[string]$html});direction=$null;format='';indent=0;type='root';version=1}}
  $lex=ConvertTo-Json $lexObj -Depth 12 -Compress
  $obj=[ordered]@{title=$title;slug=$slug;lexical=$lex;status='published';visibility='public';custom_excerpt=$excerpt;meta_title=$metaTitle;meta_description=$metaDesc;og_title=$metaTitle;og_description=$metaDesc;twitter_title=$metaTitle;twitter_description=$metaDesc;show_title_and_feature_image=$false}
  if($existing){ $obj.updated_at=$existing.updated_at;$method='Put';$uri="$apiUrl/ghost/api/admin/pages/$($existing.id)/" } else { $method='Post';$uri="$apiUrl/ghost/api/admin/pages/" }
  $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json @{pages=@($obj)} -Depth 14))
  $jwt=New-GhostJWT $adminKey
  $r=Invoke-RestMethod -Uri $uri -Method $method -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -ContentType 'application/json' -Body $bytes -TimeoutSec 40
  return $r.pages[0].url
}
$u1=Upsert-Page 'money-glossary' 'The Money Glossary' $glossHtml 'Every money term you keep hearing, explained in plain English with real dollar examples.' 'The Money Glossary: Every Term in Plain English | Thrifty Crew' 'Confused by money jargon? Our free glossary explains every term in plain English with a real dollar example. Search it or browse by topic.'
$u2=Upsert-Page 'money-hacks' 'Money Hacks and How-To Guides' $hacksHtml 'Practical, do-it-this-weekend guides that put real money back in your pocket. Free.' 'Money Hacks and How-To Guides | Thrifty Crew' 'Free, practical money guides with real numbers and copy ready scripts. Search and filter by topic to find the exact play you need.'
Write-Output ("GLOSSARY HUB: "+$u1+"  ("+$gc+" terms)")
Write-Output ("HACKS HUB:    "+$u2+"  ("+$hc+" guides)")
