<#
  test-scaler-labels.ps1 - the guard for the recipe card's INGREDIENT-LABEL SCALING rule.

  WHAT IT GUARDS. When a reader moves the servings control, every ingredient label is re-rendered by
  scaleBuy() in tpl2-scaler-prefix.html. Two shapes were rendering wrong on live cards until 2026-09-01,
  found by a post-publish review of nine recipes:

    COMPOUND   "2 lb 5 oz" is ONE quantity written in two units. scaleBuy multiplied only the leading
               number, so 28 servings rendered "4 lb 5 oz" where the truth is 4 lb 10 oz. Five ounces
               light on the main protein of a chicken lasagna, printed beside a gram figure that had
               doubled correctly. Measured that day: 8 such labels across 6 live specs.
    QUALIFIED  "about 14 cups prepared (nine 8.5 oz pouches)" and "optional: 2/3 cup ..." never scaled
               AT ALL, because the match is anchored and a word stood in front of the number. The label
               froze at base servings while its grams moved. Measured: 44 labels across 27 specs lead
               with something other than their number.

  WHY IT IS BUILT, NOT WRITTEN. Same reason as test-scaler-pricing.ps1, which this file is modelled on:
  the rule is client JS, and pasting the template's script into a checked-in page would create a SECOND
  copy that drifts silently. So this GENERATES the fixture from the real template files exactly the way
  build-card2.ps1 composes a card, including the same Compress-TcAsset minification, and adds only the
  frozen cases and the assertions. There is one copy of the scaling rule in the estate and this page
  runs it.

  THE FIXTURES (the standing rule: the founding bug plus a clean twin, both frozen):
    MUST-FIRE   the four compound labels and the two qualified ones, taken verbatim off the live cards
                they were wrong on, with the expected render computed by hand from the arithmetic.
    CLEAN TWIN  the labels this widening must NOT move: a pack SIZE ("2 pk 12 oz"), a bare fraction
                ("1/2 tsp", the 2026-07 founding bug), a label with no quantity at all, a lb+oz pair
                sitting inside a NOTE rather than at the head, an oz-then-lb label, and a two-quantity
                sentence the qualified path is required to refuse rather than half-scale.
  Every clean twin also passes under -NegativeTest, which is what makes the must-fire set meaningful:
  the mutation may only break the labels the fix was written for.

  TWO LANES, TWO LANGUAGES. -SelfTest runs the same frozen table through Invoke-CmScaleBuy, the
  PowerShell twin in cook-measure-lib.ps1, so ops\run-gates.ps1 pins the mirror on every push; the
  generated page pins the JS a reader actually runs, daily, through run-scaler-pricing-test.ps1.
  Parity between the two was measured on 2026-09-01 over 321,645 renders (every catalog label at every
  serving count from 2 to 42): 0 disagreements.

  Usage: powershell -File meal-prep\pipeline\test-scaler-labels.ps1            writes the page
         powershell -File meal-prep\pipeline\test-scaler-labels.ps1 -SelfTest  runs the PowerShell twin
#>
param([string]$OutFile = '', [switch]$NegativeTest, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# ---------------------------------------------------------------------------------------------------
# THE FROZEN TABLE. One copy, read by both lanes. base = 14 servings, so serv 28 is x2 and serv 7 is x0.5.
# `expect` is arithmetic done by hand, never by the code under test:
#   2 lb 5 oz  = 37 oz  -> x2 = 74 oz = 4 lb 10 oz
#   1 lb 2 1/2 oz = 18.5 oz -> x2 = 37 oz = 2 lb 5 oz
#   1 lb 12 oz = 28 oz -> x2 = 56 oz = 3 lb 8 oz
#   1 lb 4 oz  = 20 oz -> x0.5 = 10 oz, which is below a pound and must render as ounces alone
# ---------------------------------------------------------------------------------------------------
$CASES = @(
  @{ id='F01'; kind='MUST-FIRE'; serv=28; grams=0
     buy='2 lb 5 oz raw, cooked and roughly chopped'
     expect='4 lb 10 oz raw, cooked and roughly chopped'
     note='high-protein-chicken-alfredo-lasagna chicken breast, live and wrong at 28 servings on 2026-09-01' }
  @{ id='F02'; kind='MUST-FIRE'; serv=28; grams=0
     buy='1 lb 2 1/2 oz, roughly shredded'
     expect='2 lb 5 oz, roughly shredded'
     note='the same card fresh mozzarella; a fractional ounce carries into the pound' }
  @{ id='F03'; kind='MUST-FIRE'; serv=28; grams=0
     buy='1 lb 12 oz dry'
     expect='3 lb 8 oz dry'
     note='no-boil casserole penne; the ounces overflow a whole pound, which is what the old rule could never do' }
  @{ id='F04'; kind='MUST-FIRE'; serv=7; grams=0
     buy='1 lb 4 oz drained (about 2 1/3 cans), roughly chopped'
     expect='10 oz drained (about 2 1/3 cans), roughly chopped'
     note='scaling DOWN below a pound must drop the pound, not render "0 lb 10 oz"' }
  @{ id='F05'; kind='MUST-FIRE'; serv=28; grams=0
     buy='about 14 cups prepared (nine 8.5 oz pouches)'
     expect='about 28 cups prepared (nine 8.5 oz pouches)'
     note='blackened-chicken cilantro lime rice; a hedge word in front froze the whole label' }
  @{ id='F06'; kind='MUST-FIRE'; serv=28; grams=0
     buy='optional: 2/3 cup, to serve'
     expect='optional: 1 1/3 cup, to serve'
     note='crack-chicken-chili sour cream; "optional:" in front froze the whole label' }
  @{ id='F07'; kind='CLEAN TWIN'; serv=28; grams=0
     buy='2 pk 12 oz'
     expect='4 pk 12 oz'
     note='THE 2026-07 FOUNDING BUG: a pack SIZE is not a quantity and must never scale' }
  @{ id='F08'; kind='CLEAN TWIN'; serv=28; grams=0
     buy='1/2 tsp'
     expect='1 tsp'
     note='the other half of that bug: numerator and denominator were both scaled, giving "2/4 tsp"' }
  @{ id='F09'; kind='CLEAN TWIN'; serv=28; grams=0
     buy='a pinch'
     expect='a pinch'
     note='no quantity anywhere, and "a pinch" is not a hedge word: left exactly alone' }
  @{ id='F10'; kind='CLEAN TWIN'; serv=28; grams=0
     buy='About 1 tablespoon salt and 1 1/2 teaspoons black pepper, to taste'
     expect='About 1 tablespoon salt and 1 1/2 teaspoons black pepper, to taste'
     note='TWO bare quantities: the qualified path must REFUSE rather than move one of them (stuffed-chicken-breast, live)' }
  @{ id='F11'; kind='CLEAN TWIN'; serv=28; grams=0
     buy='10 1/2 cups (2 lb 3 oz) dry rotini'
     expect='21 cups (2 lb 3 oz) dry rotini'
     note='a lb+oz pair inside a NOTE is not the head quantity (healthy-hamburger-helper, live and correct)' }
  @{ id='F12'; kind='CLEAN TWIN'; serv=28; grams=0
     buy='28 oz sliced provolone (1 3/4 lb)'
     expect='56 oz sliced provolone (1 3/4 lb)'
     note='oz before lb is not a compound; only lb-then-oz is one quantity' }
  @{ id='F13'; kind='CLEAN TWIN'; serv=28; grams=0
     buy='to taste (about 1/4 tsp)'
     expect='to taste (about 1/4 tsp)'
     note='"to taste" is deliberately NOT a hedge word: the label states no amount to scale' }
  @{ id='F14'; kind='CLEAN TWIN'; serv=28; grams=150
     buy='1 cup'
     expect='2 cup'
     note='the gram figure still appends and still scales, beside the label (asserted separately)' }
  # ---- 2026-09-01, THE UNSCALED RENDER. The list is re-rendered through scaleBuy on every page load,
  # so an authored fraction the seven-value table cannot say was being quietly rewritten at f=1.
  @{ id='F15'; kind='MUST-FIRE'; serv=14; grams=0
     buy='7/8 cup grated'
     expect='7/8 cup grated'
     note='chicken-parmesan-pasta parmesan, live and rendering "3/4 cup grated" at BASE servings on 2026-09-01 (98 g against a 112 g cup is 0.875 exactly, an exact tie the table breaks downward)' }
  @{ id='F16'; kind='CLEAN TWIN'; serv=14; grams=0
     buy='0.6 onions'
     expect='2/3 onions'
     note='THE REGRESSION THIS FIX MUST NOT BECOME: 4,299 authored labels carry a machine decimal, and turning those into kitchen fractions at f=1 is the service, not the bug. Returning the authored string whenever f=1 moved 4,326 renders and every one was worse.' }
  @{ id='F17'; kind='CLEAN TWIN'; serv=28; grams=0
     buy='7/8 cup grated'
     expect='1 3/4 cup grated'
     note='SCOPE: the same authored fraction still scales normally at any factor but 1 - 0.875 x 2 = 1.75, which the table says exactly' }
  # ---- 2026-09-03, queue 2026-09-02-corn06: ONE AMOUNT WRITTEN IN PARTS. The 2026-09-01 fix installed
  # "a label is one quantity however many numbers it take to write it" on the lb+oz and qualified paths
  # and left the plain leading-number path explicitly unchanged, so the estate held the rule and its
  # counter-example in the same function. Measured over all 7,838 live buy labels, not the 13 the alert
  # claimed: 55 second-portion labels scaled only their leading quantity, 2 ranges scaled only their
  # first endpoint, and 4 juice/zest labels scaled nothing while their gram figure doubled.
  # Every expectation below was read off the shipped implementation, never guessed.
  @{ id='F18'; kind='MUST-FIRE'; serv=28; grams=0
     buy='1 tbsp + 1/2 tsp'
     expect='2 tbsp + 1 tsp'
     note='slow-cooker-chicken-cacciatore-pasta balsamic vinegar, live: the plus path rendered "2 tbsp + 1/2 tsp", the exact half-move the 09-01 note called worse than moving neither' }
  @{ id='F19'; kind='MUST-FIRE'; serv=28; grams=0
     buy='juice of 3 1/2 limes; 7 tablespoons'
     expect='juice of 7 limes; 14 tablespoons'
     note='street-corn-chicken-rice-bowls, live: ONE amount stated twice, and the ONLY statement of it. Scaled nothing at all before, while its 210 g doubled beside it' }
  @{ id='F20'; kind='MUST-FIRE'; serv=28; grams=0
     buy='zest of 3 1/2 limes; 3 1/2 teaspoons'
     expect='zest of 7 limes; 7 teaspoons'
     note='the sibling zest line on the same card; "zest of" admitted with "juice of" as a lead prefix' }
  @{ id='F21'; kind='MUST-FIRE'; serv=28; grams=0
     buy='1/8 to 1/2 tsp fine salt'
     expect='1/4 to 1 tsp fine salt'
     note='beef-picadillo-rice-bowls, live: a RANGE is one amount in parts, so BOTH endpoints move or neither does' }
  @{ id='F22'; kind='MUST-FIRE'; serv=28; grams=0
     buy='10 to 11 cloves, finely minced'
     expect='20 to 22 cloves, finely minced'
     note='italian-chicken-tortellini-skillet garlic, the second live range; cloves is in the closed cook-unit list' }
  @{ id='F23'; kind='MUST-FIRE'; serv=28; grams=0
     buy='1 tsp (patties) + 1/2 tsp (gravy)'
     expect='2 tsp (patties) + 1 tsp (gravy)'
     note='salisbury-steak-potato-bowls worcestershire, live: parentheticals sit BETWEEN the parts and must survive the split untouched' }
  @{ id='F24'; kind='MUST-FIRE'; serv=28; grams=0
     buy='1 cup plus 5 tbsp salted (2 sticks plus 5 tbsp)'
     expect='2 cup plus 10 tbsp salted (2 sticks plus 5 tbsp)'
     note='garlic-butter-steak-bites-zucchini butter, live. THE SPLIT IS AT PAREN DEPTH 0 ONLY: the "plus" inside the bracketed restatement must not split, and that restatement must not scale' }
  @{ id='F25'; kind='MUST-FIRE'; serv=28; grams=0
     buy='3 1/2 teaspoons for the chicken; 3 1/2 teaspoons for the cheese sauce; 3 1/2 teaspoons for the pasta water (10 1/2 teaspoons total)'
     expect='7 teaspoons for the chicken; 7 teaspoons for the cheese sauce; 7 teaspoons for the pasta water (10 1/2 teaspoons total)'
     note='honey-bbq-chicken-mac-and-cheese salt, live: THREE portions, each with trailing prose, and the parenthetical TOTAL stays frozen by the 2026-09-01 decision' }
  @{ id='F26'; kind='MUST-FIRE'; serv=28; grams=0
     buy='juice of 3 1/2 lemons (about 2/3 cup)'
     expect='juice of 7 lemons (about 2/3 cup)'
     note='chicken-piccata-skillet, live: no connector, so this one moves on the LEAD path via the new juice-of prefix' }
  # ---- THE CLEAN-TWIN CORPUS. These are the 14 measured labels whose SECOND number is a knife cut, a can
  # size, a per-unit weight, a product name or a cook time. A scale-every-number fix corrupts every one of
  # them, and they are the whole reason the connector and unit lists are closed. Each must render exactly
  # as it does today, and each also passes under -NegativeTest, which is what makes the set meaningful.
  @{ id='F27'; kind='CLEAN TWIN'; serv=28; grams=0
     buy='3 1/2 14-oz cans, undrained (about 5 3/4 cups)'
     expect='7 14-oz cans, undrained (about 5 3/4 cups)'
     note='turkey-zucchini-noodle-casserole: the CAN SIZE and the parenthetical cup restatement must not move, only the count. No connector stands between "3 1/2" and "14-oz"' }
  @{ id='F28'; kind='CLEAN TWIN'; serv=28; grams=0
     buy='4 3/4 lb, cut into 1-inch chunks'
     expect='9 1/2 lb, cut into 1-inch chunks'
     note='street-corn chicken breast: a KNIFE CUT. "into" is not the connector "to" - the connector demands whitespace on both sides, and nine of the fourteen twins depend on that' }
  @{ id='F29'; kind='CLEAN TWIN'; serv=28; grams=0
     buy='9 1/4 sweet potatoes, about 1/2 lb each'
     expect='19 sweet potatoes, about 1/2 lb each'
     note='chimichurri-steak-sheet-pan: a PER-UNIT WEIGHT. Doubling the "1/2 lb each" would say the potatoes themselves got bigger' }
  @{ id='F30'; kind='CLEAN TWIN'; serv=28; grams=0
     buy='14 oz. 1/3-less-fat cream cheese, softened'
     expect='28 oz. 1/3-less-fat cream cheese, softened'
     note='stuffed-chicken-breast: the 1/3 is part of a PRODUCT NAME, not a quantity' }
  @{ id='F31'; kind='CLEAN TWIN'; serv=28; grams=0
     buy='3 1/2 cups shredded cheddar, added the last 2 minutes'
     expect='7 cups shredded cheddar, added the last 2 minutes'
     note='sheet-pan-smoked-sausage-broccoli-cheddar: a COOK TIME. This is why "minutes" must never enter the closed cook-unit list' }
  @{ id='F32'; kind='CLEAN TWIN'; serv=28; grams=0
     buy='9 thick-cut slices, cut into 1/2-inch pieces'
     expect='18 thick-cut slices, cut into 1/2-inch pieces'
     note='country-captain-chicken bacon: a knife cut behind a COMMA, which is deliberately not a connector' }
)

# ---------------------------------------------------------------------------------------------------
if ($SelfTest) {
  # THE POWERSHELL TWIN LANE. Same table, same frozen expectations, Invoke-CmScaleBuy instead of the
  # browser. run-gates.ps1 discovers this switch and runs it on every push.
  . (Join-Path $here 'cook-measure-lib.ps1')
  $fail = 0
  foreach ($c in $CASES) {
    $got = Invoke-CmScaleBuy ([string]$c.buy) ([double]$c.serv / 14.0)
    if ($got -eq [string]$c.expect) {
      Write-Output ("ok    {0} {1}  {2}" -f $c.id, $c.kind, $c.note)
    } else {
      $fail++
      Write-Output ("FAIL  {0} {1}  {2}" -f $c.id, $c.kind, $c.note)
      Write-Output ("        label   : {0}" -f $c.buy)
      Write-Output ("        at {0,-3} servings expected: {1}" -f $c.serv, $c.expect)
      Write-Output ("        {0,-16} got     : {1}" -f '', $got)
    }
  }
  # MUST FIRE, PROVABLY. The 2026-07 implementation is re-run here over the same table so the fixture
  # can show it discriminates: a guard that has only ever been seen to pass has not been shown to catch
  # anything. Every MUST-FIRE case must fail under it and every CLEAN TWIN must still pass.
  function Invoke-OldScaleBuy([string]$buy, [double]$f) {
    $m = [regex]::Match($buy, '^(\s*)(\d+\s+\d+/\d+|\d+/\d+|\d+(?:\.\d+)?)')
    if (-not $m.Success) { return $buy }
    return ($m.Groups[1].Value + (Format-CmQty ((Get-CmQty $m.Groups[2].Value) * $f)) + $buy.Substring($m.Value.Length))
  }
  $mustFireCaught = 0; $twinBroken = @()
  foreach ($c in $CASES) {
    $old = Invoke-OldScaleBuy ([string]$c.buy) ([double]$c.serv / 14.0)
    if ($c.kind -eq 'MUST-FIRE') { if ($old -ne [string]$c.expect) { $mustFireCaught++ } }
    elseif ($old -ne [string]$c.expect) { $twinBroken += ("{0} ({1} -> {2})" -f $c.id, $c.buy, $old) }
  }
  $mustFireTotal = @($CASES | Where-Object { $_.kind -eq 'MUST-FIRE' }).Count
  if ($mustFireCaught -eq $mustFireTotal) {
    Write-Output ("ok    NEGATIVE the 2026-07 rule fails all {0} must-fire cases, so they are reachable" -f $mustFireTotal)
  } else {
    $fail++
    Write-Output ("FAIL  NEGATIVE the 2026-07 rule already satisfies {0} of {1} must-fire case(s) - the fixture has stopped reproducing the bug it exists for" -f ($mustFireTotal - $mustFireCaught), $mustFireTotal)
  }
  if ($twinBroken.Count) {
    $fail++
    Write-Output ("FAIL  NEGATIVE the 2026-07 rule also broke a CLEAN TWIN, so the mutation is not scoped to the founding bug: " + ($twinBroken -join '; '))
  } else {
    Write-Output 'ok    NEGATIVE every clean twin still passes under the 2026-07 rule (the fix moved only what it had to)'
  }
  if ($fail) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $fail); exit 1 }
  Write-Output ("SELF-TEST PASS: {0} frozen label case(s) plus both negative checks" -f $CASES.Count)
  exit 0
}

# ---------------------------------------------------------------------------------------------------
# THE BROWSER LANE: generate the fixture page from the real template.
# ---------------------------------------------------------------------------------------------------
if (-not $OutFile) { $OutFile = Join-Path $here $(if ($NegativeTest) { 'test-scaler-labels.negative.html' } else { 'test-scaler-labels.html' }) }
. (Join-Path $here '..\..\lib\design-tokens.ps1')

$prefix = Compress-TcAsset ([IO.File]::ReadAllText((Join-Path $here 'tpl2-scaler-prefix.html'), [Text.Encoding]::UTF8))

# -NegativeTest RESTORES THE 2026-07 scaleBuy, the implementation that multiplied only the leading
# number of a label. It mutates the in-memory copy only; the template on disk is never touched. The
# generated page MUST report FAIL and the failures MUST be the must-fire ones.
if ($NegativeTest) {
  $pat = '(?s)function scaleBuy\(buy,f\)\{.*?return buy;\s*\}'
  $m = [regex]::Match($prefix, $pat)
  if (-not $m.Success) {
    throw 'NEGATIVE TEST could not find scaleBuy to revert. The anchor moved: re-read tpl2-scaler-prefix.html and update this mutation, or the negative test is silently testing nothing.'
  }
  # Substring splice rather than [regex]::Replace: the replacement is JS full of $ and \ , which the
  # replacement grammar would read as capture references and escapes.
  $old = @'
function scaleBuy(buy,f){
var m=buy.match(/^(\s*)(\d+\s+\d+\/\d+|\d+\/\d+|\d+(?:\.\d+)?)/);
if(!m) return buy;
return m[1]+fmtCook(parseQty(m[2])*f)+buy.slice(m[0].length); }
'@
  $prefix = $prefix.Substring(0, $m.Index) + $old + $prefix.Substring($m.Index + $m.Length)
}
$suffix = [IO.File]::ReadAllText((Join-Path $here 'tpl2-scaler-suffix.html'), [Text.Encoding]::UTF8)

function Esc-Js([string]$s) {
  return ($s -replace '\\', '\\' -replace '"', '\"' -replace "`r", '' -replace "`n", '\n')
}

# ---- the frozen recipe, same shape build-card2.ps1 emits. gpu/pkg_g are omitted deliberately: this
# fixture asserts on the ingredient LIST, and test-scaler-pricing.ps1 already owns the cost section.
$ingParts = @()
$caseParts = @()
foreach ($c in $CASES) {
  $ingParts += ('{"item":"' + $c.id + '","disp":"' + $c.id + '","grams":' + [int]$c.grams + ',"buy":"' + (Esc-Js ([string]$c.buy)) + '"}')
  $caseParts += ('{"id":"' + $c.id + '","kind":"' + $c.kind + '","serv":' + [int]$c.serv + ',"grams":' + [int]$c.grams +
                 ',"expect":"' + (Esc-Js ([string]$c.expect)) + '","note":"' + (Esc-Js ([string]$c.note)) + '"}')
}
$scalerData = '{"slug":"zz-fixture-labels","base":14,"ing":[' + ($ingParts -join ',') + ']}'
$casesJson = '[' + ($caseParts -join ',') + ']'

# The template fetches the price feed on init. Stub it to a resolved null so the page is provably
# offline; a null feed leaves the ingredient list alone, which is the surface under test.
$harness = @'
<script>
window.__FIXTURE_CASES = __CASES__;
window.fetch = function(){ return Promise.resolve({ ok:false, json:function(){ return Promise.resolve(null); } }); };
</script>
'@
$harness = $harness.Replace('__CASES__', $casesJson)

$asserts = @'
<script>
(function(){
  var R=[], failed=0;
  function ok(name,cond,detail){ R.push({name:name,pass:!!cond,detail:detail||''}); if(!cond)failed++; }
  function setServ(n){ var i=document.querySelector('.smp-sc-num'); i.value=String(n); i.dispatchEvent(new Event('change')); }
  function labels(){
    var out={};
    [].slice.call(document.querySelectorAll('.smp-ing li')).forEach(function(li){
      var s=li.querySelector('strong'); if(!s)return;
      out[s.textContent.replace(/:\s*$/,'')]=li.textContent.slice(s.textContent.length).replace(/^\s+/,'');
    });
    return out;
  }
  function run(){
    var C=window.__FIXTURE_CASES, byServ={};
    C.forEach(function(c){ (byServ[c.serv]=byServ[c.serv]||[]).push(c); });
    Object.keys(byServ).forEach(function(sv){
      setServ(parseInt(sv,10));
      var L=labels();
      byServ[sv].forEach(function(c){
        var want=c.expect+(c.grams?(' ('+Math.round(c.grams*(parseInt(sv,10)/14))+' g)'):'');
        ok(c.kind+' '+c.id+' at '+sv+' servings: '+c.note, L[c.id]===want,
           'label "'+c.buy+'" wanted "'+want+'" got "'+(L[c.id]===undefined?'(no line)':L[c.id])+'"');
      });
    });
    // the list must not lose or gain a row while it is being re-rendered
    setServ(14);
    ok('CLEAN TWIN the list still has exactly one line per ingredient', document.querySelectorAll('.smp-ing li').length===C.length,
       'expected '+C.length+' got '+document.querySelectorAll('.smp-ing li').length);
    report();
  }
  function report(){
    var html='<h2>'+(failed?('FAIL: '+failed+' of '+R.length):('PASS: all '+R.length))+' assertion(s)</h2><ul>';
    R.forEach(function(r){ html+='<li style="color:'+(r.pass?'#0c5c3b':'#b23b2e')+'"><b>'+(r.pass?'PASS':'FAIL')+'</b> '+r.name+(r.pass?'':(' :: '+r.detail))+'</li>'; });
    document.getElementById('results').innerHTML=html+'</ul>';
    document.title = failed? 'FAIL' : 'PASS';
    window.__FIXTURE_RESULT = { pass: !failed, failed: failed, total: R.length,
      failures: R.filter(function(r){return !r.pass;}).map(function(r){return r.name+' :: '+r.detail;}) };
  }
  var tries=0;
  (function wait(){
    tries++;
    if(document.querySelectorAll('.smp-ing li').length){ try{ run(); }catch(e){ document.getElementById('results').textContent='FAIL: harness threw '+e.message; document.title='FAIL'; } return; }
    if(tries>100){ document.getElementById('results').textContent='FAIL: ingredient list never rendered'; document.title='FAIL'; return; }
    setTimeout(wait,25);
  })();
})();
</script>
'@

$page = @"
<!doctype html><html><head><meta charset="utf-8"><title>running</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font:15px/1.5 -apple-system,Segoe UI,Roboto,Arial,sans-serif;max-width:900px;margin:0 auto;padding:16px;color:#16263F}
#results{border:2px solid #16263F;border-radius:10px;padding:12px 16px;margin:0 0 20px;background:#fffdf6}
#results h2{margin:0 0 8px}#results ul{margin:0;padding-left:20px}#results li{margin:3px 0}</style></head><body>
<h1>Recipe card label-scaling fixture</h1>
<p>GENERATED by <code>meal-prep\pipeline\test-scaler-labels.ps1</code> from the real
<code>tpl2-scaler-prefix.html</code>, minified the same way a shipped card is. Do not edit this file: edit
the generator. Frozen cases, no network.</p>
<div id="results">running...</div>
$harness
<ul class="smp-ing"></ul>
$prefix$scalerData$suffix
$asserts
</body></html>
"@

[IO.File]::WriteAllText($OutFile, $page, (New-Object Text.UTF8Encoding($false)))
Write-Output ("wrote {0}" -f $OutFile)
