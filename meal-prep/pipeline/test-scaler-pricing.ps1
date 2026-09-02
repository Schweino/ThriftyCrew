<#
  test-scaler-pricing.ps1 - the guard for the recipe card's CHEAPEST-STORE SELECTION rule.

  WHAT IT GUARDS. The card's cost section prices whole packages. It used to pick, per ingredient, the store
  with the lowest PER-UNIT price and then bill the reader for a whole package at THAT store, which billed a
  Sam's Club 4 lb butter box at $10.22 for the 0.194 lb a recipe needs (Aldi's 1 lb box: $2.89) and a 50 lb
  sack of rice at $40.00 for 1.8 lb. Fixed 2026-08-15 by scanning every store cell and keeping the minimum
  COST. This fixture pins that rule.

  WHY IT IS BUILT, NOT WRITTEN. The rule is client JS. Pasting the template's script into a checked-in test
  page would create a SECOND COPY of the very rule the fix exists to de-duplicate, and the copy would drift
  silently. So this script GENERATES the fixture from the real template file
  (tpl2-scaler-prefix.html + tpl2-scaler-suffix.html) exactly the way build-card2.ps1 composes a card,
  including the same Compress-TcAsset minification the cards actually ship, and adds only a frozen mini feed
  and the assertions. There is one copy of the pricing rule in the estate and this page runs it.

  MANUAL UNTIL NODE EXISTS. The estate is PowerShell-only (checked 2026-08-15: node is not on PATH), so this
  script writes the page and you open it in the in-app browser; the page prints PASS or FAIL as text and
  sets document.title to 'PASS'/'FAIL' so a browser check can read the verdict without scraping the body.
  If node is ever installed, the same generated page can be driven headless with no change to the fixtures.

  FIXTURES (the standing rule: the founding bug plus a clean twin):
    MUST-FIRE  Butter, per-unit winner Sam's Club 4 lb / cost winner Aldi 1 lb -> line must read $2.89, chip
               Aldi, and carry NO link (the feed's url belongs to Sam's Club).
    CLEAN TWIN Salt, per-unit winner IS the cost winner -> nothing may change, and the link must survive.
    Plus: the quantity flip (a bulk line that legitimately moves TO the warehouse pack when scaled up),
    the sale tag following the WINNING cell, the everyday lane skipping sale cells, and the invariant that
    the receipt total equals the store picker's all-stores total.

  Usage: powershell -File meal-prep\pipeline\test-scaler-pricing.ps1
#>
param([string]$OutFile = '', [switch]$NegativeTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutFile) { $OutFile = Join-Path $here $(if ($NegativeTest) { 'test-scaler-pricing.negative.html' } else { 'test-scaler-pricing.html' }) }
. (Join-Path $here '..\..\lib\design-tokens.ps1')

$prefix = Compress-TcAsset ([IO.File]::ReadAllText((Join-Path $here 'tpl2-scaler-prefix.html'), [Text.Encoding]::UTF8))
# -NegativeTest RE-INTRODUCES THE FOUNDING BUG so the fixture's must-fire assertions are provably
# reachable. A guard that has only ever been seen to pass has not been shown to discriminate; this reverts
# the cheapest lane to the single pre-selected minimum-PER-UNIT cell, which is exactly the code that billed
# $10.22 for 20 cents of butter. It mutates only the in-memory copy - the template on disk is never touched.
# The generated negative page MUST report FAIL, and the failures must be the butter ones.
if ($NegativeTest) {
  $mutated = [regex]::Replace($prefix, ':\s*cheapestAcross\(it,nn,null\);', ": null;   /* NEGATIVE TEST: cheapest lane reverted to min-per-unit */`n", 1)
  if ($mutated -eq $prefix) { throw 'NEGATIVE TEST could not find the cheapest-lane scan to revert. The anchor moved: re-read price() in tpl2-scaler-prefix.html and update this mutation, or the negative test is silently testing nothing.' }
  $prefix = $mutated
}
$suffix = [IO.File]::ReadAllText((Join-Path $here 'tpl2-scaler-suffix.html'), [Text.Encoding]::UTF8)

# ---- the frozen recipe. Same shape build-card2.ps1 emits: {"slug","base",ing:[{item,disp,grams,buy,bid,gpu,pkg_g,pkg_l}]}
# Butter: 88 g at 453.592 g/lb = 0.194 lb -> one 1 lb box beats one 4 lb box. THE FOUNDING BUG.
# Bulk Butter: 544.31 g = 1.2 lb at base, so 2 Aldi boxes ($5.78) beat the Sam's 4 lb pack ($10.22); at 42
#   servings it is 3.6 lb, so 4 Aldi boxes ($11.56) LOSE to the Sam's pack and the winner must flip. A fix
#   that always prefers the small package is also wrong, and this is the line that proves it does not.
# Salt: every store sells the same 1 unit package, so the per-unit winner is the cost winner. CLEAN TWIN.
#   1.5 oz on a 1 oz package deliberately does NOT sit on a package boundary: 2 oz exactly would be
#   56.699 g and 56.7 rounds to 2.00003 packages, which correctly ceils to 3 and would make this fixture
#   assert a floating-point artifact instead of the rule it exists to pin.
# Chicken: Hy-Vee's cell is a sale and is also cheapest to buy, so the sale tag must show on the cheapest
#   tab and the everyday tab must fall through to Aldi.
# Corn: THE DRAINED-BASIS LINE (2026-09-02, queue 2026-09-02-corn04), frozen from
#   street-corn-chicken-rice-bowls. 1148 g of DRAINED corn out of cans that drain 298 g from 432 g gross,
#   so this line's gpu is 19.5559 g per oz of can, not the ingredient row's gross 28.3495. Until this
#   date the block shipped the gross number, the widget computed 1148/28.35 = 40.49 oz instead of
#   58.70 oz, and bought 3 cans where the card's own Buy N line said 4. -NegativeTest re-emits the gross
#   gpu on exactly these lines, so the assertions below are provably able to catch it coming back.
# Corn window / Corn twin: THE TOLERANCE PAIR. 597 g needs 2.0018 packages and 745 g needs 2.498. Under
#   the old ceil(x - 1e-9) the first bought THREE cans - one more than the Buy N line printed two inches
#   above it - while the second was unaffected. Aligned to the engine's ceil(x - 0.02) in the same
#   commit; the twin is here so an over-wide tolerance cannot pass by rounding everything down.
$scalerData = @'
{"slug":"zz-fixture-pricing","base":14,"ing":[
{"item":"Butter","disp":"Butter","grams":88,"buy":"6 tbsp","bid":"butter","gpu":453.592,"pkg_g":453.592,"pkg_l":"lb box"},
{"item":"Bulk Butter","disp":"Bulk Butter","grams":544.31,"buy":"1.2 lb","bid":"butter","gpu":453.592,"pkg_g":453.592,"pkg_l":"lb box"},
{"item":"Salt","disp":"Salt","grams":42.5,"buy":"1.5 oz","bid":"salt","gpu":28.3495,"pkg_g":28.3495,"pkg_l":"oz"},
{"item":"Chicken","disp":"Chicken","grams":453.592,"buy":"1 lb","bid":"chicken","gpu":453.592,"pkg_g":453.592,"pkg_l":"lb"},
{"item":"Corn","disp":"Corn","grams":1148,"buy":"4 cans","bid":"corn","gpu":19.5559,"pkg_g":298,"pkg_l":"can"},
{"item":"Corn window","disp":"Corn window","grams":597,"buy":"2 cans","bid":"corn","gpu":19.5559,"pkg_g":298,"pkg_l":"can"},
{"item":"Corn twin","disp":"Corn twin","grams":745,"buy":"3 cans","bid":"corn","gpu":19.5559,"pkg_g":298,"pkg_l":"can"}
]}
'@
$scalerData = ($scalerData -replace "`r?`n",'')
# -NegativeTest ALSO PUTS THE GROSS gpu BACK on the corn lines (2026-09-02). The template mutation above
# reverts the cheapest-store SELECTION; this reverts the data-block BASIS, which is a different founding
# bug on the same page and needs its own proof of reachability. It is a DATA mutation, not a code one,
# because that is exactly what build-card2 used to emit: 28.35 g per oz of can (the gross weight,
# packing water included) against grams and pkg_g that had already gone drained. With it back, corn
# reads 40.49 oz instead of 58.70 and the corn assertions must go red.
if ($NegativeTest) {
  $mutatedData = $scalerData.Replace('"gpu":19.5559', '"gpu":28.35')
  if ($mutatedData -eq $scalerData) { throw 'NEGATIVE TEST could not find the drained corn gpu to revert. The fixture moved: re-read the corn lines in $scalerData and update this mutation, or the basis half of this fixture is silently testing nothing.' }
  $scalerData = $mutatedData
}

# ---- the frozen feed. Real shapes: `current`/`everyday` full, `stores` lean, schema 2 with sale flags.
$feedJson = @'
{
 "schema":2,
 "week_of":"2026-08-15",
 "ingredients":{
  "butter":{"unit":"lb","cheapest":2.555,"store":"Sam's Club","type":"everyday","url":"https://example.invalid/sams-butter","n":7,
    "stores":{"Sam's Club":2.555,"Aldi":2.89,"Walmart":2.976,"Fareway":3.48,"Baker's":3.49,"Hy-Vee":3.99,"Family Fare":5.39}},
  "salt":{"unit":"oz","cheapest":1,"store":"Aldi","type":"everyday","url":"https://example.invalid/aldi-salt","n":2,
    "stores":{"Aldi":1,"Hy-Vee":1.5}},
  "chicken":{"unit":"lb","cheapest":0.99,"store":"Hy-Vee","type":"sale","url":"https://example.invalid/hyvee-chicken","n":2,
    "stores":{"Hy-Vee":0.99,"Aldi":1.99}},
  "corn":{"unit":"oz","cheapest":0.0400,"store":"Walmart","type":"everyday","url":"https://example.invalid/walmart-corn","n":2,
    "stores":{"Walmart":0.0400,"Fareway":0.0446}}
 },
 "pricing_inputs":{
  "butter":{
   "current":{"store":"Sam's Club","unit":"lb","perUnitMicros":2555000,"variableWeight":false,"packageBasisUnits":4,"purchasePriceMinor":1022,"url":"https://example.invalid/sams-butter"},
   "stores":{
    "Sam's Club":{"perUnitMicros":2555000,"variableWeight":false,"packageBasisUnits":4,"purchasePriceMinor":1022},
    "Aldi":{"perUnitMicros":2890000,"variableWeight":false,"packageBasisUnits":1,"purchasePriceMinor":289},
    "Walmart":{"perUnitMicros":2976000,"variableWeight":false,"packageBasisUnits":2.003,"purchasePriceMinor":596},
    "Fareway":{"perUnitMicros":3480000,"variableWeight":false,"packageBasisUnits":1,"purchasePriceMinor":348},
    "Baker's":{"perUnitMicros":3490000,"variableWeight":false,"packageBasisUnits":1,"purchasePriceMinor":349},
    "Hy-Vee":{"perUnitMicros":3990000,"variableWeight":false,"packageBasisUnits":1,"purchasePriceMinor":399},
    "Family Fare":{"perUnitMicros":5390000,"variableWeight":false,"packageBasisUnits":1,"purchasePriceMinor":539}}},
  "salt":{
   "current":{"store":"Aldi","unit":"oz","perUnitMicros":1000000,"variableWeight":false,"packageBasisUnits":1,"purchasePriceMinor":100,"url":"https://example.invalid/aldi-salt"},
   "stores":{
    "Aldi":{"perUnitMicros":1000000,"variableWeight":false,"packageBasisUnits":1,"purchasePriceMinor":100},
    "Hy-Vee":{"perUnitMicros":1500000,"variableWeight":false,"packageBasisUnits":1,"purchasePriceMinor":150}}},
  "chicken":{
   "current":{"store":"Hy-Vee","unit":"lb","perUnitMicros":990000,"variableWeight":false,"packageBasisUnits":1,"purchasePriceMinor":99,"sale":true,"url":"https://example.invalid/hyvee-chicken"},
   "everyday":{"store":"Aldi","unit":"lb","perUnitMicros":1990000,"variableWeight":false,"packageBasisUnits":1,"purchasePriceMinor":199},
   "stores":{
    "Hy-Vee":{"perUnitMicros":990000,"variableWeight":false,"sale":true,"packageBasisUnits":1,"purchasePriceMinor":99},
    "Aldi":{"perUnitMicros":1990000,"variableWeight":false,"packageBasisUnits":1,"purchasePriceMinor":199}}},
  "corn":{
   "current":{"store":"Fareway","unit":"oz","perUnitMicros":44600,"variableWeight":false,"packageBasisUnits":15.25,"purchasePriceMinor":68,"sale":true,"url":"https://example.invalid/fareway-corn"},
   "everyday":{"store":"Walmart","unit":"oz","perUnitMicros":40000,"variableWeight":false,"packageBasisUnits":29,"purchasePriceMinor":116},
   "stores":{
    "Fareway":{"perUnitMicros":44600,"variableWeight":false,"sale":true,"packageBasisUnits":15.25,"purchasePriceMinor":68},
    "Walmart":{"perUnitMicros":40000,"variableWeight":false,"packageBasisUnits":29,"purchasePriceMinor":116}}}
 },
 "recipes":{}
}
'@

# ---- the harness. Stubs fetch BEFORE the template's IIFE runs, then asserts on the RENDERED receipt -
# what the reader actually sees - rather than on any internal the template does not export.
$harness = @'
<script>
window.__FIXTURE_FEED = __FEED__;
window.fetch = function(){ return Promise.resolve({ ok:true, json:function(){ return Promise.resolve(window.__FIXTURE_FEED); } }); };
</script>
'@
# .Replace, NOT -replace: the feed JSON is full of $ and \ , which -replace would read as substitution
# and escape syntax. An ordinal string replace has no such grammar.
$harness = $harness.Replace('__FEED__', $feedJson)

$asserts = @'
<script>
(function(){
  var R=[], failed=0;
  function ok(name,cond,detail){ R.push({name:name,pass:!!cond,detail:detail||''}); if(!cond)failed++; }
  function q(s){ return document.querySelector(s); }
  // The package label renders '4 <multiply> 15 oz'. This .ps1 carries no BOM, so PS 5.1 decodes it
  // as ANSI and a literal U+00D7 in this file would reach the page as mojibake and fail a correct
  // render. Built from its code point instead, so the generator stays pure ASCII.
  function QX(n,p){ return n+' '+String.fromCharCode(215)+' '+p; }
  function tabTo(t){ var b=document.querySelector('.smp-ct-btn[data-t="'+t+'"]'); b.click(); }
  function lines(){
    var out={};
    [].slice.call(document.querySelectorAll('.smp-ct-list li')).forEach(function(li){
      if(li.classList.contains('smp-cp-total'))return;
      var nm=(li.querySelector('label span')||li.querySelector('span')).textContent.replace(/sale$/i,'').trim();
      var tot=li.querySelector('.smp-cp-tot'), st=li.querySelector('.smp-wst'), lp=li.querySelector('.smp-sc-lp');
      var qy=li.querySelector('.smp-ct-qty');
      out[nm]={cost:tot?tot.textContent.trim():null, store:st?st.textContent.trim():null,
               qty:qy?qy.textContent.trim():null,
               per:lp?lp.textContent.trim():null, link:li.querySelector('a')?li.querySelector('a').getAttribute('href'):null,
               sale:!!li.querySelector('.smp-sc-saletag')};
    });
    return out;
  }
  function grand(){ var g=q('.smp-ct-grand'); return g?parseFloat(g.textContent.replace(/[^0-9.]/g,'')):null; }
  function setServ(n){ var i=q('.smp-sc-num'); i.value=String(n); i.dispatchEvent(new Event('change')); }

  function run(){
    // ---------- MUST FIRE: the founding bug ----------
    tabTo('cheapest');
    var L=lines();
    ok('MUST-FIRE butter bills the 1 lb box, not the 4 lb box', L['Butter'] && L['Butter'].cost==='$2.89', 'got '+(L['Butter']?L['Butter'].cost:'no line')+' (per-unit winner Sam\'s Club would bill $10.22)');
    ok('MUST-FIRE butter chip names the store that won', L['Butter'] && L['Butter'].store==='Aldi', 'got '+(L['Butter']?L['Butter'].store:'none'));
    ok('MUST-FIRE butter per-unit figure is the winner\'s', L['Butter'] && L['Butter'].per==='$2.89/lb', 'got '+(L['Butter']?L['Butter'].per:'none'));
    ok('MUST-FIRE no link to another store\'s product', L['Butter'] && L['Butter'].link===null, 'feed url belongs to Sam\'s Club; got '+(L['Butter']?L['Butter'].link:'none'));

    // ---------- CLEAN TWIN: the fix must not move a line it has no business moving ----------
    ok('CLEAN TWIN salt unchanged at $2.00', L['Salt'] && L['Salt'].cost==='$2.00', 'got '+(L['Salt']?L['Salt'].cost:'no line'));
    ok('CLEAN TWIN salt chip still Aldi', L['Salt'] && L['Salt'].store==='Aldi', 'got '+(L['Salt']?L['Salt'].store:'none'));
    ok('CLEAN TWIN salt KEEPS its link (winner is the url\'s store)', L['Salt'] && L['Salt'].link==='https://example.invalid/aldi-salt', 'got '+(L['Salt']?L['Salt'].link:'none'));

    // ---------- sale tag follows the WINNING cell ----------
    ok('sale tag on the winning sale cell', L['Chicken'] && L['Chicken'].sale===true, 'Hy-Vee cell is the sale and the cost winner');
    ok('chicken bills the sale price', L['Chicken'] && L['Chicken'].cost==='$0.99', 'got '+(L['Chicken']?L['Chicken'].cost:'no line'));

    // ---------- MUST FIRE: the drained-basis line buys enough corn ----------
    // 1148 g of drained corn at 19.5559 g per oz of can is 58.70 oz, which is 4 cans of 15.25 oz - the
    // number the card's own Buy N line prints. On the gross gpu the widget read 40.49 oz and bought 3,
    // sending a reader home a can short. -NegativeTest puts the gross gpu back; these must fail then.
    ok('MUST-FIRE corn buys 4 cans, not 3', L['Corn'] && L['Corn'].cost==='$2.72', 'got '+(L['Corn']?L['Corn'].cost:'no line')+' (3 cans is $2.04, and 3 cans is 348 g short)');
    ok('MUST-FIRE corn names the count and the package it counted', L['Corn'] && L['Corn'].qty===QX(4,'15 oz'), 'got '+(L['Corn']?L['Corn'].qty:'no line')+' (fmtQty renders a basis over 10 whole, so a 15.25 oz can reads 15 oz)');
    ok('MUST-FIRE corn chip names the store that won', L['Corn'] && L['Corn'].store==='Fareway', 'got '+(L['Corn']?L['Corn'].store:'none'));

    // ---------- MUST FIRE: the ceil tolerance is the engine's 0.02, not floating-point noise ----------
    // 597 g is 30.53 oz, 2.0018 packages. ceil(x - 0.02) buys 2, like the Buy N line beside it;
    // ceil(x - 1e-9) bought 3. The twin at 745 g is 2.498 packages and buys 3 either way, so a
    // tolerance widened far enough to swallow real thirds of a package cannot pass this pair.
    ok('MUST-FIRE a line 0.18% over two packages buys TWO', L['Corn window'] && L['Corn window'].cost==='$1.36', 'got '+(L['Corn window']?L['Corn window'].cost:'no line')+' ($2.04 means it rounded 2.0018 up to 3)');
    ok('CLEAN TWIN a line half a package over two still buys THREE', L['Corn twin'] && L['Corn twin'].cost==='$2.04', 'got '+(L['Corn twin']?L['Corn twin'].cost:'no line'));
    ok('CLEAN TWIN and salt is still on a boundary the tolerance must not swallow', L['Salt'] && L['Salt'].cost==='$2.00', 'got '+(L['Salt']?L['Salt'].cost:'no line'));

    // ---------- the quantity flip: a warehouse pack CAN be right, and must be allowed to win ----------
    ok('bulk line takes 2 small boxes at base servings', L['Bulk Butter'] && L['Bulk Butter'].cost==='$5.78', 'got '+(L['Bulk Butter']?L['Bulk Butter'].cost:'no line'));
    var chBase=grand();
    setServ(42); tabTo('cheapest');
    var L42=lines();
    ok('QUANTITY FLIP at 42 servings the 4 lb pack wins', L42['Bulk Butter'] && L42['Bulk Butter'].cost==='$10.22' && L42['Bulk Butter'].store==='Sam\'s Club', 'got '+(L42['Bulk Butter']?(L42['Bulk Butter'].cost+' at '+L42['Bulk Butter'].store):'no line'));
    setServ(14); tabTo('cheapest');

    // ---------- everyday lane skips sale cells, and cheapest <= everyday ----------
    tabTo('everyday');
    var E=lines();
    // The everyday tab deliberately renders no store chip (it never has - renderTabs only chips the
    // cheapest and custom tabs), so this asserts the PRICE fell through to the non-sale cell, not a chip.
    ok('everyday lane skips the sale cell', E['Chicken'] && E['Chicken'].cost==='$1.99', 'got '+(E['Chicken']?E['Chicken'].cost:'no line')+' (Hy-Vee sale is $0.99 and must not be used here)');
    ok('everyday tab still shows no store chip', E['Chicken'] && E['Chicken'].store===null, 'pre-existing markup choice; a chip appearing here is an unintended change');
    ok('everyday lane shows no sale tag', E['Chicken'] && E['Chicken'].sale===false, 'a sale tag on the everyday tab is a contradiction');
    ok('everyday butter also uses the min-cost rule', E['Butter'] && E['Butter'].cost==='$2.89', 'got '+(E['Butter']?E['Butter'].cost:'no line'));
    // Corn's cheapest cell is Fareway's SALE, so the everyday lane falls to Walmart's 29 oz pack:
    // 58.70/29 = 2.024 packages, ceil(2.024 - 0.02) = 3 at $1.16 each. Hand-computed, not read off a
    // run: a fixture that freezes whatever the code printed proves only that the code is consistent.
    ok('MUST-FIRE everyday corn falls to the non-sale 29 oz pack and buys 3', E['Corn'] && E['Corn'].cost==='$3.48', 'got '+(E['Corn']?E['Corn'].cost:'no line')+' (Fareway 15.25 oz is on sale and must not price this lane)');
    ok('MUST-FIRE and it counts THAT store\'s package, not the recipe\'s', E['Corn'] && E['Corn'].qty===QX(3,'29 oz'), 'got '+(E['Corn']?E['Corn'].qty:'no line'));
    var evTot=grand();
    tabTo('cheapest');
    var chTot=grand();
    ok('cheapest <= everyday', chTot!==null && evTot!==null && chTot<=evTot+0.001, 'cheapest '+chTot+' vs everyday '+evTot);

    // ---------- THE INVARIANT: the receipt and the store picker must agree ----------
    // Same page, same feed, same servings. Before the fix these read $58.37 and $37.25 on a live recipe.
    q('.smp-shop').click();
    setTimeout(function(){
      var sum=q('.smp-stsum');
      var m=sum?sum.textContent.match(/\$([0-9.,]+)/):null;
      var pick=m?parseFloat(m[1].replace(/,/g,'')):null;
      ok('receipt total EQUALS the all-stores picker total', pick!==null && chTot!==null && Math.abs(pick-chTot)<0.005, 'receipt '+chTot+' vs picker '+pick);
      // picker "cheapest on N" must be counted with the receipt's rule
      var aldiRow=[].slice.call(document.querySelectorAll('.smp-strow')).filter(function(r){ return /Aldi/.test(r.textContent); })[0];
      // Aldi wins Butter, Bulk Butter and Salt at base servings; Hy-Vee wins the chicken on sale. Counted
      // with the receipt's own rule, this used to read the per-unit winner and credit Sam's Club instead.
      ok('picker credits Aldi for the lines it actually wins', aldiRow && /cheapest on 3/.test(aldiRow.textContent), 'expected 3 (Butter, Bulk Butter, Salt); got: '+(aldiRow?aldiRow.querySelector('.smp-stct').textContent.replace(/\s+/g,' '):'no row'));
      var samRow=[].slice.call(document.querySelectorAll('.smp-strow')).filter(function(r){ return /Sam/.test(r.textContent); })[0];
      ok('picker does NOT credit the per-unit winner it no longer wins', samRow && !/cheapest on/.test(samRow.textContent), 'Sam\'s Club wins nothing at base servings; got: '+(samRow?samRow.querySelector('.smp-stct').textContent.replace(/\s+/g,' '):'no row'));
      var x=q('.smp-stx'); if(x)x.click();
      report();
    },60);
  }
  function report(){
    var html='<h2>'+(failed?('FAIL: '+failed+' of '+R.length):('PASS: all '+R.length))+' assertion(s)</h2><ul>';
    R.forEach(function(r){ html+='<li style="color:'+(r.pass?'#0c5c3b':'#b23b2e')+'"><b>'+(r.pass?'PASS':'FAIL')+'</b> '+r.name+(r.pass?'':(' &mdash; '+r.detail))+'</li>'; });
    document.getElementById('results').innerHTML=html+'</ul>';
    document.title = failed? 'FAIL' : 'PASS';
    window.__FIXTURE_RESULT = { pass: !failed, failed: failed, total: R.length,
      failures: R.filter(function(r){return !r.pass;}).map(function(r){return r.name+' :: '+r.detail;}) };
  }
  // wait for the feed promise to have rendered real prices before asserting
  var tries=0;
  (function wait(){
    tries++;
    var g=document.querySelector('.smp-ct-grand');
    if(g && /\$/.test(g.textContent) && document.querySelectorAll('.smp-ct-list li').length>1){ try{ run(); }catch(e){ document.getElementById('results').textContent='FAIL: harness threw '+e.message; document.title='FAIL'; } return; }
    if(tries>100){ document.getElementById('results').textContent='FAIL: receipt never rendered'; document.title='FAIL'; return; }
    setTimeout(wait,25);
  })();
})();
</script>
'@

$page = @"
<!doctype html><html><head><meta charset="utf-8"><title>running</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font:15px/1.5 -apple-system,Segoe UI,Roboto,Arial,sans-serif;max-width:820px;margin:0 auto;padding:16px;color:#16263F}
#results{border:2px solid #16263F;border-radius:10px;padding:12px 16px;margin:0 0 20px;background:#fffdf6}
#results h2{margin:0 0 8px}#results ul{margin:0;padding-left:20px}#results li{margin:3px 0}</style></head><body>
<h1>Recipe card pricing fixture</h1>
<p>GENERATED by <code>meal-prep\pipeline\test-scaler-pricing.ps1</code> from the real
<code>tpl2-scaler-prefix.html</code>, minified the same way a shipped card is. Do not edit this file: edit
the generator. Frozen mini feed, no network.</p>
<div id="results">running...</div>
$harness
<ul class="smp-ing"></ul>
<div class="smp-ct"><h2>What This Batch Costs</h2>
<p class="smp-ct-save" hidden></p>
<div class="smp-ct-btns"><button type="button" class="smp-ct-btn on" data-t="custom">Customized pricing</button><button type="button" class="smp-ct-btn" data-t="everyday">Everyday cost</button><button type="button" class="smp-ct-btn" data-t="cheapest">Current cheapest pricing</button></div>
<div class="smp-rc"><p class="smp-ct-sub"></p><ul class="smp-ct-list"></ul><p class="smp-rc-kitchen" hidden></p></div>
<p style="margin:1.4rem 0 0"><button type="button" class="smp-shop">Shop this recipe</button></p>
</div>
$prefix$scalerData$suffix
$asserts
</body></html>
"@

[IO.File]::WriteAllText($OutFile, $page, (New-Object Text.UTF8Encoding($false)))
Write-Output ("fixture written -> {0}" -f $OutFile)
Write-Output 'Open it in the in-app browser. The page prints PASS/FAIL and sets document.title to the verdict.'
Write-Output ('  file:///' + ($OutFile -replace '\\','/'))
