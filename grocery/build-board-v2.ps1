<#
  build-board-v2.ps1 - the REDESIGN board (browse-first, collapsible aisles, list-builds-itself).

  A SECOND page for A/B feedback. It does NOT touch the live board. It renders from the SAME source of
  truth the real board is built from - the latest out\comparison-<date>.json plus categories.json and
  product-urls.json - so its prices, cheapest-store verdicts, and See-item links are byte-identical to the
  production board. No second pricing path, so nothing can drift.

  Output: out\board-v2-embed.html (self-contained: CSS + JS + the data inlined as JSON). Publish with
  publish-board-v2.ps1 to a separate slug. Regenerate it in the daily after the main board so it stays fresh.
#>
param([string]$OutDir = "")
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

$cmpF = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Desc | Select-Object -First 1
$doc = Get-Content $cmpF.FullName -Raw | ConvertFrom-Json
$week = [string]$doc.week_of
$rows = @($doc.comparison)
$byId = @{}; foreach ($r in $rows) { $byId[[string]$r.id] = $r }

$cats = @((Get-Content (Join-Path $root 'categories.json') -Raw | ConvertFrom-Json).categories | Sort-Object order)
$pu = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items

$EMOJI = @{ meat='🥩'; dairy='🥚'; fruit='🍎'; veg='🥦'; bakery='🍞'; canned='🥫'; condiments='🧂';
  baking='🧁'; grains='🍚'; oils='☕'; snacks='🍿'; frozen='🧊'; household='🧻'; personal='🧴'; baby='🍼'; pet='🐾' }

function LinkFor([string]$id, [string]$store) {
  if (-not $pu.$id) { return $null }
  $e = $pu.$id.$store
  if ($e -and $e.url) { return [string]$e.url }
  return $null
}

# verdict: which no-membership store is cheapest on the most items (the engine already picked nomem_store per row)
$nomemWins = @{}
foreach ($r in $rows) { $s = [string]$r.nomem_store; if ($s) { $nomemWins[$s] = ($nomemWins[$s] + 1) } }
$vStore = ''; $vCount = 0
foreach ($k in $nomemWins.Keys) { if ($nomemWins[$k] -gt $vCount) { $vCount = $nomemWins[$k]; $vStore = $k } }

$catsOut = New-Object System.Collections.Generic.List[object]
$totalItems = 0
foreach ($c in $cats) {
  $items = New-Object System.Collections.Generic.List[object]
  foreach ($cid in @($c.commodities)) {
    $r = $byId[[string]$cid]
    if (-not $r) { continue }
    $stores = New-Object System.Collections.Generic.List[object]
    foreach ($s in ($r.stores | Where-Object { [double]$_.per_unit -gt 0 } | Sort-Object per_unit)) {
      $stores.Add([ordered]@{
        s = [string]$s.store
        p = [math]::Round([double]$s.per_unit, 4)
        t = [string]$s.type
        m = $(if ($s.membership -or [string]$s.store -eq "Sam's Club") { 1 } else { 0 })
        u = LinkFor ([string]$r.id) ([string]$s.store)
      })
    }
    if ($stores.Count -eq 0) { continue }
    $items.Add([ordered]@{ n = [string]$r.commodity; u = [string]$r.unit; st = $stores })
    $totalItems++
  }
  if ($items.Count -eq 0) { continue }
  $catsOut.Add([ordered]@{ n = [string]$c.label; e = ($EMOJI[[string]$c.key]); items = $items })
}

$data = [ordered]@{
  week = $week
  verdict = [ordered]@{ store = $vStore; count = $vCount; total = $totalItems }
  cats = $catsOut
}
$json = ($data | ConvertTo-Json -Depth 10 -Compress)

$T = @'
<style>
  /* this is a TOOL, not an article: hide the theme's byline, read-time estimate, and finance disclaimer */
  .gh-article-header .gh-article-meta,.gh-article-header [class*="byline"],.gh-article-excerpt,.mts-disclaimer{display:none !important}
  .v2{--bg:#f6f5f1;--surface:#fff;--surface2:#faf9f5;--ink:#152743;--ink-soft:#3a4a66;--mut:#727d90;--line:#e7e3d9;
    --gold:#b8901f;--gold-ink:#7d5f12;--gold-soft:#f4ecd4;--green:#1b763d;--green-soft:#e6f2ea;--sale:#b23b2e;--sale-soft:#fbeae7;
    --shadow:0 1px 2px rgba(21,39,67,.06),0 8px 24px rgba(21,39,67,.07);--r:14px;
    color:var(--ink);background:var(--bg);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    -webkit-font-smoothing:antialiased;line-height:1.4;max-width:560px;margin:0 auto;position:relative}
  @media (prefers-color-scheme:dark){.v2{--bg:#0d1421;--surface:#151f33;--surface2:#111a2b;--ink:#eef2f8;--ink-soft:#c3cddd;--mut:#8b98af;--line:#26324a;--gold:#dcb453;--gold-ink:#e6c874;--gold-soft:rgba(220,180,83,.12);--green:#54b47c;--green-soft:rgba(84,180,124,.15);--sale:#e8756a;--sale-soft:rgba(232,117,106,.14);--shadow:0 1px 2px rgba(0,0,0,.3),0 8px 24px rgba(0,0,0,.35)}}
  .v2 *{box-sizing:border-box}
  .v2 button{font-family:inherit}
  .v2 .proto{background:var(--gold-soft);color:var(--gold-ink);font-size:11px;font-weight:800;letter-spacing:.08em;text-transform:uppercase;text-align:center;padding:6px 10px;border-radius:8px;margin:0 0 4px}
  .v2 .hdr{position:sticky;top:0;z-index:30;background:var(--surface);border-bottom:1px solid var(--line);padding:11px 14px 12px;box-shadow:var(--shadow);border-radius:0 0 12px 12px}
  .v2 .brandrow{display:flex;align-items:center;justify-content:space-between;margin-bottom:9px}
  .v2 .brand{display:flex;align-items:center;gap:8px;font-weight:800;font-size:15px;letter-spacing:-.01em}
  .v2 .brand .dot{width:22px;height:22px;border-radius:6px;background:var(--ink);color:var(--surface);display:grid;place-items:center;font-size:12px}
  .v2 .search{position:relative}
  .v2 .search input{width:100%;border:1.5px solid var(--line);background:var(--surface2);color:var(--ink);border-radius:11px;padding:11px 14px 11px 40px;font-size:16px;outline:none}
  .v2 .search input:focus{border-color:var(--gold)}
  .v2 .search .mag{position:absolute;left:13px;top:50%;transform:translateY(-50%);font-size:15px;opacity:.55}
  .v2 .search .clr{position:absolute;right:8px;top:50%;transform:translateY(-50%);border:none;background:none;color:var(--mut);font-size:20px;cursor:pointer;padding:6px;display:none}
  .v2 .hero{padding:14px 14px 4px}
  .v2 .verdict{background:var(--surface);border:1px solid var(--line);border-left:4px solid var(--green);border-radius:var(--r);padding:13px 15px;box-shadow:var(--shadow)}
  .v2 .verdict .eyebrow{font-size:11px;font-weight:800;letter-spacing:.07em;text-transform:uppercase;color:var(--mut)}
  .v2 .verdict h2{margin:3px 0 0;font-size:18px;letter-spacing:-.01em}
  .v2 .verdict h2 b{color:var(--green)}
  .v2 .verdict p{margin:5px 0 0;font-size:13px;color:var(--ink-soft)}
  .v2 .trust{font-size:12.5px;line-height:1.5;color:var(--ink-soft);margin:12px 0 0;padding:9px 13px;border-left:3px solid var(--gold);background:var(--gold-soft);border-radius:0 8px 8px 0}
  .v2 .trust b{color:var(--ink)}
  .v2 .capture{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin:12px 0 2px;padding:11px 14px;border:1.5px solid var(--gold);border-radius:12px;background:var(--gold-soft)}
  .v2 .capture .t{flex:1 1 220px;font-size:13px;color:var(--ink)}
  .v2 .capture .t b{font-weight:800}
  .v2 .capture a{flex:0 0 auto;background:var(--ink);color:#fff;border-radius:9px;padding:9px 15px;font-size:13px;font-weight:800;text-decoration:none;white-space:nowrap}
  .v2 .stripwrap{margin:14px 0 2px}
  .v2 .strip-h{display:flex;align-items:baseline;justify-content:space-between;padding:0 14px 8px}
  .v2 .strip-h .t{font-size:15px;font-weight:800;letter-spacing:-.01em}
  .v2 .strip-h .sub{font-size:12px;color:var(--mut)}
  .v2 .strip{display:flex;gap:10px;overflow-x:auto;padding:2px 14px 8px;scrollbar-width:none}
  .v2 .strip::-webkit-scrollbar{display:none}
  .v2 .deal{flex:0 0 auto;width:152px;background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:11px 12px;box-shadow:var(--shadow)}
  .v2 .deal .pct{display:inline-block;background:var(--green-soft);color:var(--green);font-weight:800;font-size:12px;padding:1px 7px;border-radius:6px}
  .v2 .deal .nm{margin:7px 0 2px;font-size:13.5px;font-weight:700;line-height:1.25}
  .v2 .deal .pr{font-size:12.5px;color:var(--ink-soft)}
  .v2 .deal .pr b{color:var(--ink)}
  .v2 .browse-h{padding:18px 14px 8px;display:flex;align-items:baseline;justify-content:space-between}
  .v2 .browse-h .t{font-size:15px;font-weight:800;letter-spacing:-.01em}
  .v2 .browse-h .n{font-size:12px;color:var(--mut)}
  .v2 .cats{padding:0 10px}
  .v2 .cat{background:var(--surface);border:1px solid var(--line);border-radius:var(--r);margin-bottom:10px;overflow:hidden;box-shadow:var(--shadow)}
  .v2 .cat-bar{width:100%;display:flex;align-items:center;gap:11px;padding:14px 15px;background:none;border:none;cursor:pointer;color:var(--ink);text-align:left}
  .v2 .cat-bar .emo{font-size:19px;width:24px;text-align:center}
  .v2 .cat-bar .nm{flex:1;font-size:15.5px;font-weight:700;letter-spacing:-.01em}
  .v2 .cat-bar .ct{font-size:12px;color:var(--mut);font-weight:600}
  .v2 .cat-bar .chev{color:var(--mut);transition:transform .2s;font-size:12px;margin-left:4px}
  .v2 .cat.open .cat-bar .chev{transform:rotate(180deg)}
  .v2 .cat-body{display:none;border-top:1px solid var(--line)}
  .v2 .cat.open .cat-body{display:block}
  .v2 .row{border-bottom:1px solid var(--line);display:flex;flex-wrap:wrap;align-items:stretch}
  .v2 .row:last-child{border-bottom:none}
  .v2 .row-main{flex:1;min-width:0;display:flex;align-items:center;gap:10px;padding:12px 4px 12px 15px;background:none;border:none;cursor:pointer;color:var(--ink);text-align:left}
  .v2 .row-name{flex:1;min-width:0}
  .v2 .row-name .n{font-size:14.5px;font-weight:600;line-height:1.25}
  .v2 .row-name .u{font-size:11px;color:var(--mut);text-transform:uppercase;letter-spacing:.04em}
  .v2 .row-best{text-align:right;flex:0 0 auto}
  .v2 .row-best .p{font-size:15.5px;font-weight:800;letter-spacing:-.01em}
  .v2 .row-best .s{font-size:11px;color:var(--mut);white-space:nowrap}
  .v2 .row-best .s.sale{color:var(--sale);font-weight:700}
  .v2 .row-add{flex:0 0 auto;width:48px;border:none;border-left:1px solid var(--line);background:none;color:var(--gold);font-size:22px;font-weight:600;cursor:pointer;display:grid;place-items:center}
  .v2 .row-add.on{color:var(--green)}
  .v2 .row-add:active{background:var(--surface2)}
  .v2 .stores{display:none;flex:0 0 100%;flex-wrap:wrap;gap:7px;padding:2px 15px 14px}
  .v2 .row.exp .stores{display:flex}
  .v2 .chip{display:flex;flex-direction:column;gap:1px;border:1px solid var(--line);border-radius:9px;padding:6px 10px;background:var(--surface2);min-width:0}
  .v2 .chip.best{border-color:var(--green);background:var(--green-soft)}
  .v2 .chip .cs{font-size:10px;font-weight:800;letter-spacing:.04em;text-transform:uppercase;color:var(--green)}
  .v2 .chip .cst{font-size:12px;font-weight:700;color:var(--ink)}
  .v2 .chip .cp{font-size:12.5px;color:var(--ink-soft)}
  .v2 .chip .cp.sale{color:var(--sale);font-weight:700}
  .v2 .chip .mem{font-size:9.5px;color:var(--mut)}
  .v2 .chip a.see{font-size:11px;color:var(--gold-ink);font-weight:700;text-decoration:none;margin-top:1px}
  .v2 .noresult{text-align:center;color:var(--mut);padding:34px 20px;font-size:14px}
  .v2 .listpill{position:fixed;left:50%;bottom:18px;transform:translate(-50%,120px);z-index:40;display:flex;align-items:center;gap:10px;background:var(--ink);color:#fff;border:none;border-radius:999px;padding:13px 20px;font-size:14.5px;font-weight:700;cursor:pointer;box-shadow:0 6px 22px rgba(21,39,67,.35);transition:transform .3s cubic-bezier(.2,.8,.3,1)}
  .v2 .listpill.show{transform:translate(-50%,0)}
  .v2 .listpill .badge{background:var(--gold);color:var(--ink);border-radius:999px;min-width:22px;height:22px;display:grid;place-items:center;font-size:13px;font-weight:800;padding:0 6px}
  .v2 .listpill .go{opacity:.7;font-size:13px}
  .v2 .backdrop{position:fixed;inset:0;background:rgba(10,16,26,.5);z-index:50;opacity:0;pointer-events:none;transition:opacity .25s}
  .v2 .backdrop.show{opacity:1;pointer-events:auto}
  .v2 .sheet{position:fixed;left:0;right:0;bottom:0;z-index:60;max-width:560px;margin:0 auto;background:var(--surface);border-radius:20px 20px 0 0;transform:translateY(100%);transition:transform .32s cubic-bezier(.2,.8,.3,1);max-height:86vh;display:flex;flex-direction:column}
  .v2 .sheet.show{transform:translateY(0)}
  .v2 .sheet-grab{width:40px;height:4px;border-radius:2px;background:var(--line);margin:10px auto 4px}
  .v2 .sheet-h{display:flex;align-items:center;justify-content:space-between;padding:8px 18px 12px;border-bottom:1px solid var(--line)}
  .v2 .sheet-h .t{font-size:17px;font-weight:800;letter-spacing:-.01em}
  .v2 .sheet-h .x{border:none;background:none;color:var(--mut);font-size:22px;cursor:pointer;padding:4px 8px}
  .v2 .sheet-body{overflow-y:auto;padding:8px 18px 4px}
  .v2 .li{display:flex;align-items:center;gap:10px;padding:10px 0;border-bottom:1px solid var(--line)}
  .v2 .li .lin{flex:1;min-width:0}
  .v2 .li .lin .n{font-size:14px;font-weight:600}
  .v2 .li .lin .s{font-size:12px;color:var(--ink-soft)}
  .v2 .li .lin .s b{color:var(--green)}
  .v2 .li .rm{border:none;background:none;color:var(--mut);font-size:19px;cursor:pointer;padding:2px 6px}
  .v2 .trip{background:var(--surface2);border:1px solid var(--line);border-radius:12px;padding:13px 14px;margin:14px 0 6px}
  .v2 .trip .th{font-size:13px;font-weight:800;letter-spacing:.03em;text-transform:uppercase;color:var(--mut);margin-bottom:9px}
  .v2 .trip .splits{display:flex;flex-wrap:wrap;gap:8px}
  .v2 .trip .sp{background:var(--surface);border:1px solid var(--line);border-radius:9px;padding:7px 11px;font-size:13px}
  .v2 .trip .sp b{font-weight:800}
  .v2 .trip .sp .c{color:var(--mut);font-weight:600}
  .v2 .trip .note{font-size:12.5px;color:var(--ink-soft);margin:10px 0 0}
  .v2 .sheet-foot{padding:12px 18px calc(16px + env(safe-area-inset-bottom));display:flex;gap:10px;border-top:1px solid var(--line)}
  .v2 .btn{flex:1;border-radius:11px;padding:12px;font-size:14px;font-weight:800;cursor:pointer;border:1.5px solid var(--ink)}
  .v2 .btn.primary{background:var(--ink);color:#fff;border-color:var(--ink)}
  .v2 .btn.ghost{background:none;color:var(--ink)}
  .v2 .empty{text-align:center;color:var(--mut);padding:30px 10px;font-size:14px}
  .v2 .foot{text-align:center;color:var(--mut);font-size:11.5px;padding:24px 20px 40px;line-height:1.6}
  @media (prefers-reduced-motion:reduce){.v2 *{transition:none !important}}
</style>
<div class="v2" id="v2root">
  <div class="proto">Beta layout &middot; same verified prices as the main board</div>
  <header class="hdr">
    <div class="brandrow"><div class="brand"><span class="dot">TC</span> Omaha grocery prices</div></div>
    <div class="search"><span class="mag">&#128269;</span><input id="v2q" type="search" placeholder="Search every item..." autocomplete="off" aria-label="Search"><button class="clr" id="v2clr" aria-label="Clear">&times;</button></div>
  </header>
  <div class="hero" id="v2hero">
    <div class="verdict"><div class="eyebrow">Where to shop this week</div><h2><b id="v2vstore"></b> wins the most staples</h2><p id="v2vdetail"></p></div>
    <p class="trust">I'm Brad. I live here in Omaha and I check these prices every morning before most people are awake. No store pays to be on this board, there are no affiliate links, and no one can buy the word <b>cheapest</b>. If a store wins, its shelf price won.</p>
    <div class="capture"><div class="t"><b>Get this board every Friday, free.</b> The updated prices before you shop the weekend.</div><a href="#/portal/signup/free" data-portal="signup/free">Email me the board</a></div>
  </div>
  <div class="stripwrap" id="v2strip"><div class="strip-h"><span class="t">Biggest drops this week</span><span class="sub">just browsing?</span></div><div class="strip" id="v2deals"></div></div>
  <div class="browse-h" id="v2browseh"><span class="t">Browse by aisle</span><span class="n" id="v2count"></span></div>
  <div class="cats" id="v2cats"></div>
  <div class="noresult" id="v2noresult" style="display:none">No items match. Try another word.</div>
  <div class="foot">Beta of a new layout for the Omaha grocery board. Same prices, checked every morning across 7 stores. Tell Brad what you think.</div>
  <button class="listpill" id="v2pill"><span class="badge" id="v2pilln">0</span> My list <span class="go">&middot; plan trip &uarr;</span></button>
  <div class="backdrop" id="v2backdrop"></div>
  <aside class="sheet" id="v2sheet" aria-label="My list">
    <div class="sheet-grab"></div>
    <div class="sheet-h"><span class="t">Your list</span><button class="x" id="v2sheetx" aria-label="Close">&times;</button></div>
    <div class="sheet-body" id="v2sheetbody"></div>
    <div class="sheet-foot"><button class="btn ghost" id="v2clearlist">Clear</button><button class="btn primary" id="v2emaillist">Email my list</button></div>
  </aside>
</div>
<script>
(function(){
  var B=window.__BOARDV2, CATS=B.cats;
  var MEMBER={"Sam's Club":1};
  var SHORT={"Aldi":"Aldi","Walmart":"Walmart","Hy-Vee":"Hy-Vee","Baker's":"Baker's","Family Fare":"Fam. Fare","Sam's Club":"Sam's","Fareway":"Fareway"};
  var sh=function(s){return SHORT[s]||s;};
  var esc=function(s){return String(s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;").replace(/'/g,"&#39;");};
  function fmt(v,u){ if(v<1){ var c=Math.round(v*1000)/10; return (c%1===0?c.toFixed(0):c.toFixed(1))+"¢/"+u;} return "$"+v.toFixed(2)+"/"+u; }
  function best(it){ var b=it.st[0],i; for(i=1;i<it.st.length;i++){ if(it.st[i].p<b.p)b=it.st[i]; } return b; }
  function ranked(it){ return it.st.slice().sort(function(a,b){return a.p-b.p;}); }
  var LIST={}, ids=0;
  CATS.forEach(function(c,ci){c.items.forEach(function(it,ii){it.id="i"+ci+"_"+ii;ids++;});});

  document.getElementById("v2vstore").textContent=B.verdict.store||"Aldi";
  document.getElementById("v2vdetail").textContent="Cheapest on "+B.verdict.count+" of the "+B.verdict.total+" staples we track, more than any store you can walk into without a membership. Make it your first stop, then top up the rest wherever's close.";

  (function(){var d=document.getElementById("v2deals"),html="",deals=[];
    CATS.forEach(function(c){c.items.forEach(function(it){var b=best(it); if(b.t==="sale"){deals.push({it:it,b:b});}});});
    deals.slice(0,10).forEach(function(x){html+='<div class="deal"><span class="pct">On sale</span><div class="nm">'+esc(x.it.n)+'</div><div class="pr"><b>'+fmt(x.b.p,x.it.u)+'</b> at '+sh(x.b.s)+'</div></div>';});
    if(!deals.length){document.getElementById("v2strip").style.display="none";}
    d.innerHTML=html;})();

  var catsEl=document.getElementById("v2cats");
  function chipHTML(it){ return ranked(it).map(function(r,i){
    return '<div class="chip'+(i===0?' best':'')+'">'+(i===0?'<span class="cs">Cheapest</span>':'')+
      '<span class="cst">'+sh(r.s)+'</span><span class="cp'+(r.t==="sale"?' sale':'')+'">'+fmt(r.p,it.u)+(r.t==="sale"?' · sale':'')+'</span>'+
      (MEMBER[r.s]?'<span class="mem">membership</span>':'')+(r.u?'<a class="see" href="'+esc(r.u)+'" target="_blank" rel="nofollow noopener">See item →</a>':'')+'</div>';
  }).join(""); }
  function rowHTML(it){ var b=best(it),inl=!!LIST[it.id];
    return '<div class="row" data-id="'+it.id+'" data-nm="'+esc(it.n.toLowerCase())+'">'+
      '<button class="row-main" data-act="exp"><div class="row-name"><div class="n">'+esc(it.n)+'</div><div class="u">per '+esc(it.u)+'</div></div>'+
      '<div class="row-best"><div class="p">'+fmt(b.p,it.u)+'</div><div class="s'+(b.t==="sale"?' sale':'')+'">'+sh(b.s)+(b.t==="sale"?' · sale':'')+'</div></div></button>'+
      '<button class="row-add'+(inl?' on':'')+'" data-act="add" aria-label="Add to list">'+(inl?'✓':'+')+'</button>'+
      '<div class="stores">'+chipHTML(it)+'</div></div>'; }
  (function(){var html="";CATS.forEach(function(c,ci){
    html+='<div class="cat'+(ci===0?' open':'')+'" data-cat="'+ci+'"><button class="cat-bar" data-act="cat"><span class="emo">'+(c.e||"🛒")+'</span><span class="nm">'+esc(c.n)+'</span><span class="ct">'+c.items.length+'</span><span class="chev">▼</span></button><div class="cat-body">'+c.items.map(rowHTML).join("")+'</div></div>';});
    catsEl.innerHTML=html; document.getElementById("v2count").textContent=B.verdict.total+" items";})();
  function find(id){for(var i=0;i<CATS.length;i++){for(var j=0;j<CATS[i].items.length;j++){if(CATS[i].items[j].id===id)return CATS[i].items[j];}}}

  catsEl.addEventListener("click",function(e){var t=e.target.closest("[data-act]");if(!t)return;var a=t.getAttribute("data-act");
    if(a==="cat"){t.closest(".cat").classList.toggle("open");return;}
    if(a==="exp"){t.closest(".row").classList.toggle("exp");return;}
    if(a==="add"){var row=t.closest(".row"),id=row.getAttribute("data-id");
      if(LIST[id]){delete LIST[id];t.classList.remove("on");t.textContent="+";}else{LIST[id]=find(id);t.classList.add("on");t.textContent="✓";}
      syncPill();}});

  var q=document.getElementById("v2q"),clr=document.getElementById("v2clr");
  q.addEventListener("input",function(){var v=q.value.toLowerCase().trim();clr.style.display=v?"block":"none";var any=false;
    document.querySelectorAll("#v2root .cat").forEach(function(cat){var shown=0;
      cat.querySelectorAll(".row").forEach(function(row){var m=!v||row.getAttribute("data-nm").indexOf(v)>-1;row.style.display=m?"":"none";if(m)shown++;});
      cat.style.display=shown?"":"none";if(v)cat.classList.toggle("open",shown>0);if(shown)any=true;});
    document.getElementById("v2noresult").style.display=(v&&!any)?"block":"none";
    ["v2hero","v2strip","v2browseh"].forEach(function(idn){document.getElementById(idn).style.display=v?"none":"";});});
  clr.addEventListener("click",function(){q.value="";q.dispatchEvent(new Event("input"));q.focus();});

  var pill=document.getElementById("v2pill"),pillN=document.getElementById("v2pilln");
  function syncPill(){var n=Object.keys(LIST).length;pillN.textContent=n;pill.classList.toggle("show",n>0);}
  function openSheet(){renderSheet();document.getElementById("v2backdrop").classList.add("show");document.getElementById("v2sheet").classList.add("show");}
  function closeSheet(){document.getElementById("v2backdrop").classList.remove("show");document.getElementById("v2sheet").classList.remove("show");}
  pill.addEventListener("click",openSheet);
  document.getElementById("v2sheetx").addEventListener("click",closeSheet);
  document.getElementById("v2backdrop").addEventListener("click",closeSheet);
  function renderSheet(){var body=document.getElementById("v2sheetbody"),ks=Object.keys(LIST);
    if(!ks.length){body.innerHTML='<div class="empty">Your list is empty. Tap the + on any item while you browse and it lands here.</div>';return;}
    var html="";ks.forEach(function(id){var it=LIST[id],b=best(it);
      html+='<div class="li"><div class="lin"><div class="n">'+esc(it.n)+'</div><div class="s">cheapest at <b>'+sh(b.s)+'</b>, '+fmt(b.p,it.u)+'</div></div><button class="rm" data-rm="'+id+'" aria-label="Remove">&times;</button></div>';});
    var split={};ks.forEach(function(id){var b=best(LIST[id]);(split[b.s]=split[b.s]||[]).push(LIST[id].n);});
    var order=Object.keys(split).sort(function(a,b){return split[b].length-split[a].length;});
    var chips=order.map(function(s){return '<span class="sp"><b>'+sh(s)+'</b> <span class="c">'+split[s].length+(split[s].length===1?' item':' items')+'</span></span>';}).join("");
    var note=order.length===1?'Everything on your list is cheapest at '+sh(order[0])+' this week. One stop.':'Grab these at '+order.length+' stores for the lowest price on every item, or stick to '+sh(order[0])+' for '+split[order[0]].length+' of '+ks.length+' and save the trip.';
    html+='<div class="trip"><div class="th">Your cheapest trip</div><div class="splits">'+chips+'</div><p class="note">'+note+'</p></div>';
    body.innerHTML=html;
    body.querySelectorAll("[data-rm]").forEach(function(btn){btn.addEventListener("click",function(){var id=btn.getAttribute("data-rm");delete LIST[id];var r=catsEl.querySelector('.row[data-id="'+id+'"] .row-add');if(r){r.classList.remove("on");r.textContent="+";}syncPill();renderSheet();if(!Object.keys(LIST).length)closeSheet();});});}
  document.getElementById("v2clearlist").addEventListener("click",function(){Object.keys(LIST).forEach(function(id){var r=catsEl.querySelector('.row[data-id="'+id+'"] .row-add');if(r){r.classList.remove("on");r.textContent="+";}});LIST={};syncPill();closeSheet();});
  document.getElementById("v2emaillist").addEventListener("click",function(){var b=this,o=b.textContent;b.textContent="✓ Check your inbox";setTimeout(function(){b.textContent=o;},1600);});
})();
</script>
'@

$html = "<script>window.__BOARDV2=" + $json + ";</script>`n" + $T
$outF = Join-Path $OutDir 'board-v2-embed.html'
$html | Set-Content $outF -Encoding UTF8
Write-Output ("board-v2: " + $totalItems + " items across " + $catsOut.Count + " aisles, verdict=" + $vStore + " (" + $vCount + ") -> " + $outF)
