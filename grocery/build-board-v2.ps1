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
    --shadow:0 1px 2px rgba(21,39,67,.06),0 8px 24px rgba(21,39,67,.07);--r:14px;--btnbg:#152743;--btnfg:#ffffff;
    color:var(--ink);background:var(--bg);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    -webkit-font-smoothing:antialiased;line-height:1.4;width:100%;min-width:0;max-width:700px;margin:0 auto;position:relative}
  @media (prefers-color-scheme:dark){.v2{--bg:#0d1421;--surface:#151f33;--surface2:#111a2b;--ink:#eef2f8;--ink-soft:#c3cddd;--mut:#8b98af;--line:#26324a;--gold:#dcb453;--gold-ink:#e6c874;--gold-soft:rgba(220,180,83,.12);--green:#54b47c;--green-soft:rgba(84,180,124,.15);--sale:#e8756a;--sale-soft:rgba(232,117,106,.14);--btnbg:#eef2f8;--btnfg:#152743;--shadow:0 1px 2px rgba(0,0,0,.3),0 8px 24px rgba(0,0,0,.35)}}
  .v2 *{box-sizing:border-box}
  .v2 button{font-family:inherit}
  .v2 .proto{background:var(--gold-soft);color:var(--gold-ink);font-size:11px;font-weight:800;letter-spacing:.08em;text-transform:uppercase;text-align:center;padding:6px 10px;border-radius:8px;margin:0 0 4px}
  .v2 .hdr{position:sticky;top:0;z-index:30;background:var(--surface);border-bottom:1px solid var(--line);padding:11px 14px 12px;box-shadow:var(--shadow);border-radius:0 0 12px 12px}
  .v2 .brandrow{display:flex;align-items:center;justify-content:space-between;margin-bottom:9px}
  .v2 .brand{display:flex;align-items:center;gap:8px;font-weight:800;font-size:15px;letter-spacing:-.01em}
  .v2 .brand .dot{width:22px;height:22px;border-radius:6px;background:var(--btnbg);color:var(--btnfg);display:grid;place-items:center;font-size:12px}
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
  .v2 .capture a{flex:0 0 auto;background:var(--btnbg);color:var(--btnfg);border-radius:9px;padding:9px 15px;font-size:13px;font-weight:800;text-decoration:none;white-space:nowrap}
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
  .v2 .row-chev{flex:0 0 auto;color:var(--mut);font-size:12px;margin-left:3px;transition:transform .2s}
  .v2 .row.exp .row-chev{transform:rotate(180deg);color:var(--gold)}
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
  .v2 .listpill{position:fixed;left:50%;bottom:18px;transform:translate(-50%,120px);z-index:40;display:flex;align-items:center;gap:10px;background:var(--btnbg);color:var(--btnfg);border:none;border-radius:999px;padding:13px 20px;font-size:14.5px;font-weight:700;cursor:pointer;box-shadow:0 6px 22px rgba(21,39,67,.35);transition:transform .3s cubic-bezier(.2,.8,.3,1)}
  .v2 .listpill.show{transform:translate(-50%,0)}
  .v2 .listpill .badge{background:var(--gold);color:#152743;border-radius:999px;min-width:22px;height:22px;display:grid;place-items:center;font-size:13px;font-weight:800;padding:0 6px}
  .v2 .listpill .go{opacity:.7;font-size:13px}
  .v2 .backdrop{position:fixed;inset:0;background:rgba(10,16,26,.5);z-index:50;opacity:0;pointer-events:none;transition:opacity .25s}
  .v2 .backdrop.show{opacity:1;pointer-events:auto}
  .v2 .sheet{position:fixed;left:0;right:0;bottom:0;z-index:60;max-width:700px;margin:0 auto;background:var(--surface);border-radius:20px 20px 0 0;transform:translateY(100%);transition:transform .32s cubic-bezier(.2,.8,.3,1);max-height:86vh;display:flex;flex-direction:column}
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
  .v2 .btn.primary{background:var(--btnbg);color:var(--btnfg);border-color:var(--btnbg)}
  .v2 .btn.ghost{background:none;color:var(--ink)}
  .v2 .empty{text-align:center;color:var(--mut);padding:30px 10px;font-size:14px}
  .v2 .howto{font-size:13.5px;line-height:1.55;color:var(--ink-soft);margin:0;padding:12px 15px;border:1px solid var(--line);border-radius:13px;background:var(--surface)}
  .v2 .howto b{color:var(--ink);font-weight:800}
  .v2 .wiz-q{font-size:13.5px;font-weight:800;color:var(--ink);margin:18px 0 9px}
  .v2 .wiz-q:first-child{margin-top:2px}
  .v2 .stopts{display:flex;flex-direction:column}
  .v2 .stopt{display:flex;align-items:center;gap:11px;padding:10px 3px;border-bottom:1px solid var(--line);font-size:14.5px;cursor:pointer}
  .v2 .stopt input{width:19px;height:19px;flex:0 0 auto;accent-color:var(--ink);cursor:pointer}
  .v2 .stopt em{color:var(--mut);font-style:normal;font-size:12px;margin-left:2px}
  .v2 .kbtns{display:flex;gap:9px;flex-wrap:wrap}
  .v2 .kbtn{width:48px;height:48px;border-radius:12px;border:1.5px solid var(--line);background:var(--surface);color:var(--ink);font-size:18px;font-weight:800;cursor:pointer;transition:.12s}
  .v2 .kbtn.on{border-color:var(--btnbg);background:var(--btnbg);color:var(--btnfg)}
  .v2 .plan-sum{font-size:13.5px;font-weight:800;color:var(--ink);margin:2px 0 14px}
  .v2 .plan-store{margin:0 0 16px}
  .v2 .plan-store-h{display:flex;align-items:baseline;gap:8px;font-size:15px;font-weight:800;color:var(--ink);border-bottom:2px solid var(--ink);padding-bottom:5px;margin-bottom:3px}
  .v2 .plan-store-h .mem{font-size:10px;font-weight:700;color:var(--mut);text-transform:uppercase;letter-spacing:.04em}
  .v2 .plan-store-h .c{margin-left:auto;font-size:12px;font-weight:600;color:var(--mut);white-space:nowrap}
  .v2 .plan-item{display:flex;justify-content:space-between;gap:10px;padding:8px 2px;border-bottom:1px dotted var(--line);font-size:14.5px}
  .v2 .plan-item .pp{color:var(--ink-soft);font-weight:700;white-space:nowrap}
  .v2 .plan-un{font-size:12.5px;color:var(--mut);margin:14px 0 0;line-height:1.5}
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
    <p class="howto"><b>Search your items</b> above and tap the <b>+</b> to drop each one into your list. When you are done, tap <b>My list</b> at the bottom and we will build the cheapest shopping trip for you.</p>
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
    <div class="sheet-h"><span class="t" id="v2sheettitle">Your list</span><button class="x" id="v2sheetx" aria-label="Close">&times;</button></div>
    <div class="sheet-body" id="v2sheetbody"></div>
    <div class="sheet-foot" id="v2sheetfoot"></div>
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

  // (verdict block removed per Brad; the instruction line replaces it. B.verdict.total still drives the item count below.)

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
      '<div class="row-best"><div class="p">'+fmt(b.p,it.u)+'</div><div class="s'+(b.t==="sale"?' sale':'')+'">'+sh(b.s)+(b.t==="sale"?' · sale':'')+'</div></div><span class="row-chev">&#9662;</span></button>'+
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

  // every store that appears anywhere on the board, in shopping order
  var ALL_STORES=(function(){var s={};CATS.forEach(function(c){c.items.forEach(function(it){it.st.forEach(function(x){s[x.s]=1;});});});return Object.keys(s);})();
  var STORE_ORDER={"Aldi":1,"Walmart":2,"Hy-Vee":3,"Baker's":4,"Family Fare":5,"Fareway":6,"Sam's Club":7};
  ALL_STORES.sort(function(a,b){return (STORE_ORDER[a]||9)-(STORE_ORDER[b]||9);});
  var wiz={step:1,excluded:{},maxStores:2};

  function priceAt(it,store){var r=null;it.st.forEach(function(x){if(x.s===store)r=x.p;});return r;}
  function combosOf(arr,k){var res=[];(function rec(start,cur){if(cur.length===k){res.push(cur.slice());return;}for(var i=start;i<arr.length;i++){cur.push(arr[i]);rec(i+1,cur);cur.pop();}})(0,[]);return res;}
  function solvePlan(items,allowed,K){
    var kk=Math.min(K,allowed.length);if(kk<1)kk=1;
    var gmin=items.map(function(it){var m=null;allowed.forEach(function(s){var x=priceAt(it,s);if(x!==null&&(m===null||x<m))m=x;});return m;});
    var combos=combosOf(allowed,kk),bestC=null;
    combos.forEach(function(cmb){var score=0;items.forEach(function(it,i){var m=null;cmb.forEach(function(st){var x=priceAt(it,st);if(x!==null&&(m===null||x<m))m=x;});if(m===null)score+=10;else if(gmin[i]>0)score+=m/gmin[i];});if(bestC===null||score<bestC.score)bestC={combo:cmb,score:score};});
    var combo=bestC?bestC.combo:[],byStore={},uncovered=[];
    combo.forEach(function(st){byStore[st]=[];});
    items.forEach(function(it){var m=null,ms=null;combo.forEach(function(st){var x=priceAt(it,st);if(x!==null&&(m===null||x<m)){m=x;ms=st;}});if(ms===null)uncovered.push(it.n);else byStore[ms].push({n:it.n,p:m,u:it.u});});
    return {byStore:byStore,uncovered:uncovered};
  }
  function planStores(plan){return Object.keys(plan.byStore).filter(function(s){return plan.byStore[s].length>0;}).sort(function(a,b){return plan.byStore[b].length-plan.byStore[a].length;});}

  function openSheet(){wiz.step=1;document.getElementById("v2backdrop").classList.add("show");document.getElementById("v2sheet").classList.add("show");renderWiz();}
  function closeSheet(){document.getElementById("v2backdrop").classList.remove("show");document.getElementById("v2sheet").classList.remove("show");}
  pill.addEventListener("click",openSheet);
  document.getElementById("v2sheetx").addEventListener("click",closeSheet);
  document.getElementById("v2backdrop").addEventListener("click",closeSheet);

  function renderWiz(){
    var ks=Object.keys(LIST),title=document.getElementById("v2sheettitle"),body=document.getElementById("v2sheetbody"),foot=document.getElementById("v2sheetfoot");
    if(!ks.length){title.textContent="Your list";body.innerHTML='<div class="empty">Your list is empty. Tap the + on any item while you browse and it lands here.</div>';foot.innerHTML="";return;}
    if(wiz.step===1){
      title.textContent="Your list ("+ks.length+")";
      var h="";ks.forEach(function(id){var it=LIST[id],b=best(it);h+='<div class="li"><div class="lin"><div class="n">'+esc(it.n)+'</div><div class="s">cheapest '+fmt(b.p,it.u)+' at '+sh(b.s)+'</div></div><button class="rm" data-rm="'+id+'" aria-label="Remove">&times;</button></div>';});
      body.innerHTML=h;
      foot.innerHTML='<button class="btn ghost" data-w="clear">Clear</button><button class="btn primary" data-w="s2">Go to store selection &rarr;</button>';
    } else if(wiz.step===2){
      title.textContent="Choose your stores";
      var allowed=ALL_STORES.filter(function(s){return !wiz.excluded[s];});
      var rows=ALL_STORES.map(function(s){return '<label class="stopt"><input type="checkbox" data-store="'+esc(s)+'"'+(wiz.excluded[s]?"":" checked")+'><span>'+esc(sh(s))+(MEMBER[s]?' <em>needs membership</em>':'')+'</span></label>';}).join("");
      var maxN=Math.max(1,allowed.length),kb="";
      for(var k=1;k<=Math.min(maxN,5);k++){kb+='<button class="kbtn'+(wiz.maxStores===k?" on":"")+'" data-k="'+k+'">'+k+'</button>';}
      body.innerHTML='<p class="wiz-q">Uncheck any store you would rather not shop at.</p><div class="stopts">'+rows+'</div><p class="wiz-q">How many stores are you willing to visit for the cheapest haul?</p><div class="kbtns">'+kb+'</div>';
      foot.innerHTML='<button class="btn ghost" data-w="s1">&larr; Back</button><button class="btn primary" data-w="s3">See my plan &rarr;</button>';
    } else {
      title.textContent="Your shopping plan";
      var allowed3=ALL_STORES.filter(function(s){return !wiz.excluded[s];});
      if(!allowed3.length){body.innerHTML='<div class="empty">You unchecked every store. Go back and leave at least one.</div>';foot.innerHTML='<button class="btn ghost" data-w="s2">&larr; Back</button>';return;}
      var plan=solvePlan(ks.map(function(id){return LIST[id];}),allowed3,wiz.maxStores),stores=planStores(plan);
      var covered=ks.length-plan.uncovered.length;
      var ph='<p class="plan-sum">'+stores.length+' store'+(stores.length===1?"":"s")+', '+covered+' of '+ks.length+' items at their cheapest.</p>';
      stores.forEach(function(st){ph+='<div class="plan-store"><div class="plan-store-h">'+esc(sh(st))+(MEMBER[st]?' <span class="mem">membership</span>':'')+' <span class="c">'+plan.byStore[st].length+' item'+(plan.byStore[st].length===1?"":"s")+'</span></div>';plan.byStore[st].forEach(function(it){ph+='<div class="plan-item"><span>'+esc(it.n)+'</span><span class="pp">'+fmt(it.p,it.u)+'</span></div>';});ph+='</div>';});
      if(plan.uncovered.length)ph+='<p class="plan-un"><b>Not sold at your chosen stores:</b> '+plan.uncovered.map(esc).join(", ")+'</p>';
      body.innerHTML=ph;
      foot.innerHTML='<button class="btn ghost" data-w="s2">&larr; Back</button><button class="btn primary" data-w="print">Print list</button>';
    }
  }

  function printPlan(){
    var ks=Object.keys(LIST);if(!ks.length)return;
    var allowed=ALL_STORES.filter(function(s){return !wiz.excluded[s];});if(!allowed.length)return;
    var plan=solvePlan(ks.map(function(id){return LIST[id];}),allowed,wiz.maxStores),stores=planStores(plan);
    var w=window.open("","_blank");if(!w){alert("Allow pop-ups to print your list.");return;}
    var h='<html><head><title>My Thrifty Crew shopping list</title><style>body{font-family:-apple-system,Segoe UI,Arial,sans-serif;color:#111;max-width:620px;margin:22px auto;padding:0 18px}h1{font-size:21px;margin:0 0 2px}.sub{color:#666;font-size:12px;margin:0 0 14px}h2{font-size:15px;border-bottom:2px solid #111;padding-bottom:4px;margin:20px 0 6px}.it{display:flex;justify-content:space-between;padding:5px 0;border-bottom:1px dotted #ccc;font-size:14px}.un{color:#666;font-size:13px;margin-top:16px}@media print{body{margin:0}}</style></head><body>';
    h+='<h1>My shopping list</h1><p class="sub">Thrifty Crew &middot; thriftycrew.com/omaha-grocery-prices &middot; prices checked this morning</p>';
    stores.forEach(function(st){h+='<h2>'+esc(sh(st))+(MEMBER[st]?' (membership)':'')+'</h2>';plan.byStore[st].forEach(function(it){h+='<div class="it"><span>&#9744; '+esc(it.n)+'</span><span>'+fmt(it.p,it.u)+'</span></div>';});});
    if(plan.uncovered.length)h+='<p class="un"><b>Not at your chosen stores:</b> '+plan.uncovered.map(esc).join(", ")+'</p>';
    h+='</body></html>';
    w.document.write(h);w.document.close();w.focus();setTimeout(function(){try{w.print();}catch(e){}},350);
  }

  function removeItem(id){delete LIST[id];var r=catsEl.querySelector('.row[data-id="'+id+'"] .row-add');if(r){r.classList.remove("on");r.textContent="+";}syncPill();if(!Object.keys(LIST).length){closeSheet();}else{renderWiz();}}
  function clearList(){Object.keys(LIST).forEach(function(id){var r=catsEl.querySelector('.row[data-id="'+id+'"] .row-add');if(r){r.classList.remove("on");r.textContent="+";}});LIST={};syncPill();closeSheet();}

  var sheetEl=document.getElementById("v2sheet");
  sheetEl.addEventListener("click",function(e){
    var rm=e.target.closest("[data-rm]");if(rm){removeItem(rm.getAttribute("data-rm"));return;}
    var kb=e.target.closest("[data-k]");if(kb){wiz.maxStores=parseInt(kb.getAttribute("data-k"),10);renderWiz();return;}
    var w=e.target.closest("[data-w]");if(w){var a=w.getAttribute("data-w");
      if(a==="clear")clearList();else if(a==="s1"){wiz.step=1;renderWiz();}else if(a==="s2"){wiz.step=2;renderWiz();}else if(a==="s3"){wiz.step=3;renderWiz();}else if(a==="print")printPlan();return;}
  });
  sheetEl.addEventListener("change",function(e){
    var cb=e.target.closest("[data-store]");if(!cb)return;
    var s=cb.getAttribute("data-store");if(cb.checked)delete wiz.excluded[s];else wiz.excluded[s]=1;
    var allowed=ALL_STORES.filter(function(x){return !wiz.excluded[x];});if(wiz.maxStores>allowed.length)wiz.maxStores=Math.max(1,allowed.length);
    renderWiz();
  });
})();
</script>
'@

$html = "<script>window.__BOARDV2=" + $json + ";</script>`n" + $T
$outF = Join-Path $OutDir 'board-v2-embed.html'
$html | Set-Content $outF -Encoding UTF8
Write-Output ("board-v2: " + $totalItems + " items across " + $catsOut.Count + " aisles, verdict=" + $vStore + " (" + $vCount + ") -> " + $outF)
