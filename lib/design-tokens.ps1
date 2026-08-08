# design-tokens.ps1 - THE single design system for every Thrifty Crew surface.
#
# Created 2026-07-31 for the v1 redesign + the elite layer (income\design\design-elite-layer-2026-07-31.md
# and redesign-board-mealprep-2026-07-31.md). Before this file every builder re-declared navy/gold/cream
# and its own ad hoc margins, so "half adopted" was the default state and nothing read as one product.
#
# Dot-source it and call the emitters:
#   . (Join-Path $PSScriptRoot '..\lib\design-tokens.ps1')
#   $css = Get-TcTokenCss                 # <style> block: variables, type scale, depth, motion, z-ladder
#   $js  = Get-TcMotionJs                 # <script> block: shared number tween, check draw, haptics, wake lock
#   $acc = Get-TcStoreAccents             # store name -> hex, READ FROM grocery\stores.json (registry rule)
#
# RULES THIS FILE ENCODES (they are load-bearing, not taste):
#  * GOLD IS MONEY. #E2A43C is reserved for savings, records, totals and FREE. If gold starts meaning
#    "this is a heading" the wow becomes noise and every real money moment stops reading as one.
#  * LIGHT ONLY, ON THE RECORD (Brad, elite-layer decision 6). color-scheme:light is declared once here and
#    one navy theme-color serves both schemes. Do NOT add a dark variant to any single surface: a half dark
#    site is worse than a light one, and the receipts/ledger/chalkboard motifs are built on warm paper.
#  * ONE MOTION VOCABULARY. One easing, three durations, transforms+opacity only (never layout properties),
#    and the whole layer sits inside prefers-reduced-motion:no-preference.
#  * BOTTOM-EDGE STACKING IS A LADDER, NOT A RACE. See --tc-z-* below; at most one bar plus one transient.
#
# The self-checks (Test-TcNavyAdjacency, Test-TcGoldDiscipline) are cheap greps the builders call on their
# own output, per the elite-layer rule that these two rules are "enforced by a self-check, not a comment".

$script:TcInk       = '#16263F'   # ink navy: heads, body ink, app chrome
$script:TcInkLink   = '#1E3A5F'   # link navy (also the masthead gradient's light end)
$script:TcInkDeep   = '#101B2E'   # chalkboard: the ONE dark panel on the board
$script:TcGold      = '#E2A43C'   # MONEY ONLY
$script:TcGoldHover = '#d9992f'
$script:TcGoldInk   = '#8a6d1f'   # gold that has to pass AA on cream (eyebrows, small text)
$script:TcCream     = '#fdf8ec'   # aside/panel cream
$script:TcPaper     = '#fffdf6'   # receipt paper (warmer + lighter than cream so a receipt reads as ON the page)
$script:TcGreen     = '#10794e'
$script:TcGreenD    = '#0c5c3b'
$script:TcMut       = '#5a6862'
$script:TcRule      = '#e7e2d4'   # warm hairline (replaces cold #e2e8f0 grays)
$script:TcRuleD     = '#ddd6c2'   # letterpress bottom rule

# Per-store accents. Seven stores, seven stable hues, defined ONCE in the canonical registry
# (grocery\stores.json, per the stores-registry rule) so adding an eighth store is one edit in one file.
# The fallback map exists only so a builder outside the grocery tree still renders; it names ALL seven
# stores on purpose (audit-store-registry.ps1 flags any list that names >=3 but not all of them).
function Get-TcStoreAccents {
  $fallback = [ordered]@{
    'Hy-Vee'='#c4342c'; 'Aldi'='#1b64b0'; 'Family Fare'='#2e7d43'; 'Fareway'='#7b3fa0';
    "Baker's"='#c56a1a'; "Sam's Club"='#0b6d9e'; 'Walmart'='#0f7a8c'
  }
  $f = Join-Path $PSScriptRoot '..\grocery\stores.json'
  if (-not (Test-Path $f)) { return $fallback }
  try {
    $reg = Get-Content $f -Raw | ConvertFrom-Json
    $out = [ordered]@{}
    foreach ($s in ($reg.stores | Sort-Object order)) {
      $n = [string]$s.name
      $c = if ($s.PSObject.Properties.Name -contains 'color' -and $s.color) { [string]$s.color } elseif ($fallback.Contains($n)) { [string]$fallback[$n] } else { $script:TcInkLink }
      $out[$n] = $c
    }
    if ($out.Count -lt 1) { return $fallback }
    return $out
  } catch { return $fallback }
}

# CSS custom properties for the store dots, emitted into the token block so every surface (board rows,
# expanded cards, score strip, receipt lines, footer provenance) reads the same hue for the same store.
function Get-TcStoreAccentCss {
  $acc = Get-TcStoreAccents
  $lines = @()
  foreach ($k in $acc.Keys) {
    $slug = ((([string]$k).ToLower() -replace "[^a-z0-9]+", "-").Trim('-'))
    $lines += ('--tc-store-' + $slug + ':' + $acc[$k])
  }
  return ($lines -join ';')
}

<#
  Get-TcTokenCss - the whole design system as one <style> block.

  -Scope  : a selector the LAYOUT classes are nested under so a builder can keep its rules off the rest of
            the Ghost theme (the board passes '.pg-wrap'). Custom properties always land on :root, which is
            safe and is what lets one builder's markup reference another's tokens.
  -NoRoot : skip the :root{} declaration when a page already got it from another block on the same page
            (the hub and the board never render together, but a recipe post + a tool embed can).
#>
function Get-TcTokenCss {
  param(
    [string]$Scope = '',
    [switch]$NoRoot,
    # Which blocks to emit. Every surface pays for the bytes it ships, so a recipe post does not carry the
    # board's ledger/chalkboard rules and the hub does not carry the receipt tear edges. 'all' is the default
    # so a new caller is never accidentally missing a primitive it uses.
    [string[]]$Parts = @('all')
  )
  $want = { param($n) return (($Parts -contains 'all') -or ($Parts -contains $n)) }
  $s = if ($Scope) { $Scope + ' ' } else { '' }
  $root = ''
  if (-not $NoRoot) {
    $root = @"
:root{color-scheme:light;
--tc-ink:$script:TcInk;--tc-ink-link:$script:TcInkLink;--tc-ink-deep:$script:TcInkDeep;
--tc-gold:$script:TcGold;--tc-gold-h:$script:TcGoldHover;--tc-gold-ink:$script:TcGoldInk;
--tc-cream:$script:TcCream;--tc-paper:$script:TcPaper;--tc-green:$script:TcGreen;--tc-green-d:$script:TcGreenD;
--tc-mut:$script:TcMut;--tc-rule:$script:TcRule;--tc-rule-d:$script:TcRuleD;
--tc-ease:cubic-bezier(0.2,0,0,1);--tc-dur-press:100ms;--tc-dur-state:200ms;--tc-dur-chor:300ms;
--tc-r-card:14px;--tc-r-chip:10px;
--tc-z-mode:2147483000;--tc-z-interstitial:2147482000;--tc-z-bar:2147481000;--tc-z-transient:2147480000;
$(Get-TcStoreAccentCss)}
"@
  }
  # NOTE ON THE Z-LADDER (binding, elite-layer "Bottom-edge stacking policy"): full-screen modes beat the
  # join interstitial, which beats the one primary action bar, which beats transient pills. The interstitial
  # reads --tc-z-mode occupancy through the body class below rather than guessing; see Get-TcMotionJs.
  $B = [ordered]@{}
  $B['type'] = @"
/* --- TYPE SCALE: three fixed Georgia steps, applied to EVERY section head in one pass. A half-adopted
   scale reads worse than none, which is why this is one class set and not per-builder margins. --- */
${s}.tc-title{font-family:Georgia,'Times New Roman',serif;font-size:2.1em;line-height:1.15;letter-spacing:-.015em;color:var(--tc-ink);margin:0 0 .35em}
${s}.tc-h{font-family:Georgia,'Times New Roman',serif;font-size:1.45em;line-height:1.2;letter-spacing:-.015em;color:var(--tc-ink);margin:0 0 .3em}
${s}.tc-h3{font-family:Georgia,'Times New Roman',serif;font-size:1.1em;line-height:1.25;color:var(--tc-ink);margin:0 0 .25em}
/* The section stanza: gold letterspaced eyebrow, Georgia head, one muted dek line. 56px of air above. */
${s}.tc-stanza{margin:56px 0 18px}
${s}.tc-stanza:first-child{margin-top:0}
${s}.tc-eyebrow{display:block;font-size:.72em;font-weight:800;letter-spacing:.14em;text-transform:uppercase;color:var(--tc-gold-ink);margin:0 0 .4em}
${s}.tc-dek{font-size:.94em;line-height:1.5;color:var(--tc-mut);margin:.15em 0 0;max-width:64ch}
/* Prices are ALWAYS plain text nodes in tabular figures: no superscript spans, because the PowerShell
   builders and the JS templates render the same numbers and must stay byte-interchangeable. */
${s}.tc-price,${s}.tc-num{font-variant-numeric:tabular-nums;font-weight:750}
"@
  $B['depth'] = @"
/* --- DEPTH: three levels, replacing flat 1px gray. Cards only. Never buttons, never pills. --- */
${s}.tc-card{background:#fff;border:1px solid var(--tc-rule);border-bottom:3px solid var(--tc-rule-d);border-radius:var(--tc-r-card)}
${s}.tc-card-raised,${s}.tc-card.is-raised{border-bottom-color:var(--tc-gold);box-shadow:0 6px 16px rgba(22,38,63,.08);transform:translateY(-1px)}
${s}.tc-chip{border-radius:var(--tc-r-chip)}
"@
  $B['navy'] = @"
/* --- NAVY BANDS: full-column panels. Cream is for asides. Never two navy bands adjacent, never navy
   behind body prose. Both rules are grep-checked by Test-TcNavyAdjacency in the builders. --- */
${s}.tc-navy{background:var(--tc-ink);color:#F6F1E7;border-radius:var(--tc-r-card);padding:18px 20px}
${s}.tc-navy .tc-h,${s}.tc-navy .tc-title,${s}.tc-navy .tc-h3{color:#F6F1E7}
${s}.tc-navy .tc-eyebrow{color:var(--tc-gold)}
${s}.tc-navy .tc-dek{color:#b9c4d4}
${s}.tc-navy-grad{background:radial-gradient(120% 160% at 50% 0%,$script:TcInkLink 0%,$script:TcInk 62%);box-shadow:inset 0 1px 0 rgba(226,164,60,.35)}
"@
  $B['money'] = @"
/* --- MONEY: gold means savings, records, totals, FREE. Nothing else. --- */
${s}.tc-money{color:var(--tc-gold)}
${s}.tc-save{color:var(--tc-green-d);font-variant-numeric:tabular-nums;font-weight:750}
"@
  $B['focus'] = @"
/* --- FOCUS: one visible ring everywhere, keyboard only. --- */
${s}a:focus-visible,${s}button:focus-visible,${s}input:focus-visible,${s}select:focus-visible,${s}[tabindex]:focus-visible{outline:2px solid var(--tc-gold);outline-offset:2px;border-radius:4px}
"@
  $B['touch'] = @"
/* --- TOUCH: 44px minimum on anything tappable, and :active parity so phones get press feedback too. --- */
${s}.tc-tap{min-height:44px;min-width:44px}
${s}.tc-press{transition:transform var(--tc-dur-press) var(--tc-ease)}
${s}.tc-press:active{transform:scale(.985)}
"@
  $B['stack'] = @"
/* --- STACKING LADDER (binding). At most ONE bar plus ONE transient on screen. --- */
${s}.tc-mode{position:fixed;inset:0;z-index:var(--tc-z-mode);overscroll-behavior:contain}
${s}.tc-bar{position:fixed;left:0;right:0;bottom:0;z-index:var(--tc-z-bar);padding-bottom:calc(10px + env(safe-area-inset-bottom))}
${s}.tc-transient{position:fixed;z-index:var(--tc-z-transient);bottom:calc(64px + env(safe-area-inset-bottom))}
"@
  $B['receipt'] = @"
/* --- RECEIPT MATERIAL: paper, tear teeth, dotted leaders, double rule, ink stamp. The tear edge is a
   pure-CSS gradient zigzag (no images, no extra nodes) so it costs nothing on a phone. --- */
${s}.tc-receipt{position:relative;background:var(--tc-paper);border:1px solid var(--tc-rule);border-radius:2px;box-shadow:0 2px 10px rgba(22,38,63,.07)}
${s}.tc-receipt::before,${s}.tc-receipt::after{content:'';position:absolute;left:0;right:0;height:8px;
  background:linear-gradient(-45deg,transparent 0 5.66px,var(--tc-paper) 0) 0 0/16px 16px repeat-x,
             linear-gradient(45deg,transparent 0 5.66px,var(--tc-paper) 0) 0 0/16px 16px repeat-x}
${s}.tc-receipt::before{top:-8px;transform:scaleY(-1)}
${s}.tc-receipt::after{bottom:-8px}
${s}.tc-lead{flex:1 1 auto;min-width:12px;align-self:flex-end;border-bottom:1px dotted #c9c0a8;transform:translateY(-.32em)}
${s}.tc-rule2{border:0;border-top:3px double var(--tc-ink);margin:.55em 0 .5em}
${s}.tc-qty{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.86em;color:var(--tc-mut)}
${s}.tc-stamp{display:inline-block;transform:rotate(-4deg);border:2px solid var(--tc-gold-ink);color:var(--tc-gold-ink);
  border-radius:4px;padding:2px 9px;font-size:.72em;font-weight:800;letter-spacing:.1em;text-transform:uppercase;opacity:.82}
"@
  $B['ledger'] = @"
/* --- LEDGER MATERIAL: index tabs, double rule section openers, warm hairlines. --- */
${s}.tc-ledger-head{position:relative;border-top:3px double var(--tc-ink);padding:10px 0 6px 14px}
${s}.tc-ledger-head::before{content:'';position:absolute;left:0;top:12px;width:5px;height:20px;border-radius:0 3px 3px 0;background:var(--tc-gold)}
"@
  $B['motion'] = @"
/* --- MOTION: one easing, three durations, transforms and opacity only. Everything that moves lives
   inside this query, so reduced-motion users get the same layout with none of the choreography. --- */
@media (prefers-reduced-motion:no-preference){
  ${s}.tc-anim{transition:transform var(--tc-dur-state) var(--tc-ease),opacity var(--tc-dur-state) var(--tc-ease),box-shadow var(--tc-dur-state) var(--tc-ease)}
  ${s}.tc-fade-in{animation:tcFade var(--tc-dur-chor) var(--tc-ease) both}
  ${s}.tc-strike{animation:tcStrike var(--tc-dur-state) var(--tc-ease) forwards}
  ${s}.tc-pulse{animation:tcPulse 520ms var(--tc-ease)}
  ${s}.tc-shimmer{position:relative;overflow:hidden}
  ${s}.tc-shimmer::after{content:'';position:absolute;inset:0;transform:translateX(-120%);
    background:linear-gradient(100deg,transparent 30%,rgba(226,164,60,.38) 50%,transparent 70%);animation:tcShim 1200ms var(--tc-ease) 1}
  @keyframes tcFade{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}
  @keyframes tcStrike{from{background-size:0 1.5px}to{background-size:100% 1.5px}}
  @keyframes tcPulse{0%{background-color:rgba(226,164,60,.22)}100%{background-color:transparent}}
  @keyframes tcShim{to{transform:translateX(120%)}}
}
"@
  $B['check'] = @"
${s}.tc-check path{stroke-dashoffset:0}
@media (prefers-reduced-motion:no-preference){${s}.tc-check path{stroke-dasharray:24;transition:stroke-dashoffset 140ms var(--tc-ease)}${s}.tc-check:not(.is-on) path{stroke-dashoffset:24}}
/* --- 24px CHECKBOX, one spec everywhere (elite-layer conflict ruling). Real input, visually replaced,
   so screen readers, forms and Escape all keep working. --- */
${s}.tc-ck{position:relative;display:inline-flex;align-items:center;justify-content:center;width:24px;height:24px;flex:none}
${s}.tc-ck input{position:absolute;inset:0;width:100%;height:100%;margin:0;opacity:0;cursor:pointer}
${s}.tc-ck .tc-ck-box{width:24px;height:24px;border:2px solid var(--tc-ink);border-radius:6px;background:#fff;display:block}
${s}.tc-ck svg{position:absolute;width:16px;height:16px;pointer-events:none}
${s}.tc-ck input:checked ~ .tc-ck-box{border-color:var(--tc-gold-ink)}
"@
  $B['skel'] = @"
/* --- SKELETON: async slots show nothing for 300ms, then this. Never a spinner forever. --- */
${s}.tc-skel{background:var(--tc-cream);border-radius:8px;height:1em;margin:.45em 0;opacity:.75}
${s}.tc-skel:nth-child(2){width:82%}${s}.tc-skel:nth-child(3){width:64%}
@media (prefers-reduced-motion:no-preference){${s}.tc-skel{animation:tcSkel 1.1s var(--tc-ease) infinite alternate}@keyframes tcSkel{to{opacity:.35}}}
${s}.tc-degraded{font-size:.88em;color:var(--tc-mut);line-height:1.5;margin:.4em 0 0}
"@
  $B['sr'] = @"
/* --- SR-only, used by the tween announcer --- */
${s}.tc-sr{position:absolute!important;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;border:0}
"@
  # 'sr' is not optional: the tween announcer writes into it on every surface that tweens a number.
  $sbOut = New-Object System.Text.StringBuilder
  [void]$sbOut.Append($root)
  foreach ($k in $B.Keys) { if ($k -eq 'sr' -or (& $want $k)) { [void]$sbOut.Append("`n"); [void]$sbOut.Append($B[$k]) } }
  return $sbOut.ToString()
}

<#
  Compress-TcCss / Compress-TcAsset - the wire-size pass.

  Every recipe post carries its own copy of the token block and the widget, 513 times over, so comments
  that are load-bearing IN SOURCE are pure weight ON THE WIRE. This strips CSS comments, whole-line JS
  comments, and indentation, and touches nothing else: it never reorders, never renames, never removes a
  semicolon. Whole-line-only JS comment stripping is deliberate (a trailing // could sit inside a string).
#>
function Compress-TcCss {
  param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Css)
  $c = [regex]::Replace($Css, '/\*.*?\*/', '', [Text.RegularExpressions.RegexOptions]::Singleline)
  $c = ($c -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) -join ''
  return $c
}
function Compress-TcJs {
  param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Js)
  $keep = @()
  foreach ($ln in ($Js -split "`n")) {
    $t = $ln.TrimEnd("`r").Trim()
    if ($t -eq '') { continue }
    if ($t.StartsWith('//')) { continue }
    $keep += $t
  }
  return ($keep -join "`n")
}
# Compress an HTML fragment in place: <style> gets the CSS pass, <script> gets the JS pass, markup is
# left byte-identical (attribute quoting and whitespace inside tags are load-bearing for the audits' regexes).
function Compress-TcAsset {
  param([Parameter(Mandatory=$true)][string]$Html)
  # CRLF -> LF across the WHOLE fragment, first (2026-08-08). The two passes below each normalize line
  # endings inside their own tag - Compress-TcCss splits on \n and trims, Compress-TcJs does TrimEnd("`r") -
  # but the markup BETWEEN the tags is deliberately left byte-identical, and these templates are CRLF files.
  # So exactly the newlines outside a <style>/<script> kept their \r: one of them, the </style>\r\n<script>
  # boundary, rode into all 542 recipe cards. Ghost normalizes CRLF to LF on the round-trip, so a body
  # containing one can never read back equal, and publish.ps1's pre-flight then reports every card as
  # drifted the moment its content genuinely changes. Same class as the __GHOST_URL__ expansion, except
  # this one we are doing to ourselves - so fix it at the source rather than folding it in the comparison.
  $Html = $Html -replace "`r`n", "`n" -replace "`r", "`n"
  $h = [regex]::Replace($Html, '(?s)(<style[^>]*>)(.*?)(</style>)', { param($m) $m.Groups[1].Value + (Compress-TcCss $m.Groups[2].Value) + $m.Groups[3].Value })
  $h = [regex]::Replace($h, '(?s)(<script(?![^>]*type=["'']application/(?:json|ld\+json)["''])[^>]*>)(.*?)(</script>)', { param($m) $m.Groups[1].Value + (Compress-TcJs $m.Groups[2].Value) + $m.Groups[3].Value })
  return $h
}

<#
  Get-TcMotionJs - the shared motion + app-feel helpers, about 40 lines, emitted once per page.

  window.TC.tween(el, from, to, fmt)  one rAF number tween; announces the FINAL value to aria-live once,
                                      never per frame (a per-frame announcement is a screen-reader DoS).
  window.TC.tap(n)                    haptic tick where supported, silent everywhere else.
  window.TC.wake(on)                  screen wake lock for Aisle/Cook mode, re-acquired on visibilitychange.
  window.TC.mode(open)                sets body.tc-mode-open, which is how the join interstitial knows to
                                      stay down: the ladder is READ from the DOM, never guessed.
  window.TC.rm()                      true when the user asked for reduced motion.
#>
function Get-TcMotionJs {
@'
<script>
(function(){
if(window.TC&&window.TC.tween)return; var TC=window.TC=window.TC||{};
TC.rm=function(){try{return window.matchMedia('(prefers-reduced-motion: reduce)').matches;}catch(e){return false;}};
var live=null;
function announce(t){try{if(!live){live=document.createElement('div');live.className='tc-sr';live.setAttribute('aria-live','polite');document.body.appendChild(live);}live.textContent=t;}catch(e){}}
// ONE number tween for the whole site. 300ms, the shared easing, transform-free (it writes text), and it
// announces only the settled value so assistive tech hears "$47.30", not 18 intermediate numbers.
TC.tween=function(el,from,to,fmt){
  if(!el)return; fmt=fmt||function(v){return '$'+v.toFixed(2);};
  if(TC.rm()||from===to){el.textContent=fmt(to);announce(fmt(to));return;}
  var t0=null,d=300;
  function step(ts){ if(t0===null)t0=ts; var p=Math.min(1,(ts-t0)/d); var e=1-Math.pow(1-p,3);
    el.textContent=fmt(from+(to-from)*e); if(p<1){requestAnimationFrame(step);} else {announce(fmt(to));} }
  requestAnimationFrame(step);
};
TC.tap=function(n){ try{ if(navigator.vibrate) navigator.vibrate(n||10); }catch(e){} };
// Wake lock: the screen must not sleep while someone is holding the phone in an aisle or over a pan.
// Silent no-op where unsupported (iOS below 16.4), and re-acquired when the tab comes back.
var _wl=null,_wlWant=false;
function _acq(){ if(!_wlWant||_wl)return; try{ if(navigator.wakeLock&&navigator.wakeLock.request){ navigator.wakeLock.request('screen').then(function(s){_wl=s;s.addEventListener('release',function(){_wl=null;});}).catch(function(){}); } }catch(e){} }
document.addEventListener('visibilitychange',function(){ if(document.visibilityState==='visible')_acq(); });
TC.wake=function(on){ _wlWant=!!on; if(on){_acq();} else { try{ if(_wl)_wl.release(); }catch(e){} _wl=null; } };
// The stacking ladder, read from the DOM. Anything that wants the bottom edge asks first.
TC.mode=function(open){ try{ document.body.classList.toggle('tc-mode-open',!!open); document.documentElement.style.overflow=open?'hidden':'';
  // Broadcast rather than let each bar poll: an IntersectionObserver never re-fires just because a mode
  // opened, so a pill that only checks the ladder at intersection time would sit there flagged as visible.
  document.dispatchEvent(new CustomEvent('tc:mode',{detail:{open:!!open}})); }catch(e){} };
TC.modeOpen=function(){ try{ return document.body.classList.contains('tc-mode-open'); }catch(e){ return false; } };
TC.barUp=function(){ try{ return !!document.querySelector('.tc-bar:not([hidden])'); }catch(e){ return false; } };
// Focus trap + Escape + return-focus, shared by every sheet and full-screen mode.
TC.trap=function(el,onClose){
  var prev=document.activeElement;
  function foc(){ return el.querySelectorAll('a[href],button:not([disabled]),input,select,textarea,[tabindex]:not([tabindex="-1"])'); }
  function keys(e){
    if(e.key==='Escape'){ e.preventDefault(); onClose(); return; }
    if(e.key!=='Tab')return;
    var f=foc();
    if(!f.length)return; var a=f[0],b=f[f.length-1];
    if(e.shiftKey&&document.activeElement===a){e.preventDefault();b.focus();}
    else if(!e.shiftKey&&document.activeElement===b){e.preventDefault();a.focus();}
  }
  el.addEventListener('keydown',keys);
  // Pull focus INTO the sheet, here, so no caller can forget it. The handler is bound to the element, but
  // opening a sheet leaves focus on the button that opened it - outside el - so Escape reaches nothing and
  // the sheet is keyboard-inescapable until the user happens to Tab in. Sheets with nothing focusable take
  // focus on the container itself.
  try{
    if(!el.contains(document.activeElement)){
      var first=foc()[0];
      if(first){ first.focus({preventScroll:true}); }
      else { el.setAttribute('tabindex','-1'); el.focus({preventScroll:true}); }
    }
  }catch(e){ try{ var f0=foc()[0]; if(f0) f0.focus(); }catch(e2){} }
  return function(){ el.removeEventListener('keydown',keys); try{ if(prev&&prev.focus)prev.focus(); }catch(e){} };
};
TC.money=function(v){ return '$'+(Math.round(v*100)/100).toFixed(2); };
})();
</script>
'@
}

# The 8 functional icons, one MIT-derived stroke set on a 24px grid, 1.75px round caps, currentColor.
# NEVER on board rows (node budget): eyebrows, category heads, the stat band and the footer only.
$script:TcIcons = @{
  basket   = '<path d="M4 9h16l-1.4 9.2A2 2 0 0 1 16.6 20H7.4a2 2 0 0 1-2-1.8L4 9Z"/><path d="m8 9 2-5m6 5-2-5"/>'
  tag      = '<path d="M3 12.5V4.5A1.5 1.5 0 0 1 4.5 3h8L21 11.5 12.5 20 3 12.5Z"/><circle cx="7.5" cy="7.5" r="1.2"/>'
  receipt  = '<path d="M6 3v18l2-1.4L10 21l2-1.4L14 21l2-1.4L18 21V3H6Z"/><path d="M9 8h6M9 12h6M9 16h3"/>'
  flame    = '<path d="M12 3c3 3.4 5.5 5.6 5.5 9a5.5 5.5 0 0 1-11 0C6.5 9.3 8.4 7.7 9 6c1.2 1.4 2 2 3 3-.6-2 0-4 0-6Z"/>'
  pin      = '<path d="M12 21s7-5.6 7-11a7 7 0 1 0-14 0c0 5.4 7 11 7 11Z"/><circle cx="12" cy="10" r="2.6"/>'
  calendar = '<rect x="3.5" y="5" width="17" height="15.5" rx="2"/><path d="M8 3v4m8-4v4M3.5 10h17"/>'
  envelope = '<rect x="3" y="5.5" width="18" height="13" rx="2"/><path d="m3.6 6.7 8.4 6.1 8.4-6.1"/>'
  check    = '<path d="m5 12.5 4.5 4.5L19 7.5"/>'
}
function Get-TcIcon {
  param([Parameter(Mandatory=$true)][string]$Name, [int]$Size = 18, [string]$Class = '')
  if (-not $script:TcIcons.ContainsKey($Name)) { throw "Get-TcIcon: unknown icon '$Name' (have: $($script:TcIcons.Keys -join ', '))" }
  $c = if ($Class) { " class='" + $Class + "'" } else { '' }
  return "<svg$c width='$Size' height='$Size' viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='1.75' stroke-linecap='round' stroke-linejoin='round' aria-hidden='true' focusable='false'>" + $script:TcIcons[$Name] + "</svg>"
}

<#
  Get-TcProvenanceHtml - ONE provenance system (elite-layer conflict ruling). One include emits the badge
  class and the copy template; the board stamps the date at build, the hub and recipe pages fill it in
  client side from the feed's freshness field.

  ONCE PER PAGE, NEVER PER ROW. And never a build-time "this morning" on a surface that does not rebuild
  daily: a stale "checked this morning" is the exact kind of small lie the whole board exists to not tell.
#>
function Get-TcProvenanceHtml {
  param([string]$Stamp = '', [int]$PriceCount = 0, [int]$StoreCount = 7)
  $txt = if ($Stamp) {
    $n = if ($PriceCount -gt 0) { 'from ' + ('{0:N0}' -f $PriceCount) + ' shelf prices across ' + $StoreCount + ' Omaha stores' } else { 'across ' + $StoreCount + ' Omaha stores' }
    'Priced ' + $Stamp + ' ' + $n
  } else { 'Priced from real Omaha shelf prices' }
  return "<p class='tc-prov' data-tc-prov='1'>" + (Get-TcIcon -Name 'receipt' -Size 15 -Class 'tc-prov-ic') + "<span class='tc-prov-t'>" + $txt + "</span></p>"
}
function Get-TcProvenanceCss {
  param([string]$Scope = '')
  $s = if ($Scope) { $Scope + ' ' } else { '' }
@"
${s}.tc-prov{display:flex;align-items:center;gap:7px;font-size:.84em;color:var(--tc-mut);margin:.9em 0 0;line-height:1.45}
${s}.tc-prov-ic{color:var(--tc-gold-ink);flex:none}
"@
}

# --- SELF-CHECKS -----------------------------------------------------------------------------------
# These exist because the elite-layer spec says the navy-band rules are "enforced by a cheap self-check
# grep in the builders, not just a comment". A comment is a rule that silently disarms.

# Two navy bands may never sit adjacent (the eye reads them as one enormous block and the page loses its
# rhythm), and navy may never sit behind body prose. Returns the offending snippets; empty means clean.
function Test-TcNavyAdjacency {
  param([Parameter(Mandatory=$true)][string]$Html)
  $bad = @()
  # adjacency: a tc-navy element that closes and is IMMEDIATELY followed by another tc-navy opener
  foreach ($m in [regex]::Matches($Html, "(?is)class=['""][^'""]*tc-navy[^'""]*['""].{0,4000}?</div>\s*<div[^>]*class=['""][^'""]*tc-navy")) {
    $bad += ('adjacent navy bands near: ' + $m.Value.Substring(0, [math]::Min(90, $m.Value.Length)))
  }
  # prose inside a navy band: more than 320 characters of running text is an article, not a panel
  foreach ($m in [regex]::Matches($Html, "(?is)class=['""][^'""]*tc-navy[^'""]*['""][^>]*>(.*?)</div>")) {
    $inner = ($m.Groups[1].Value -replace '<[^>]+>', '')
    if ($inner.Length -gt 320) { $bad += ('navy band carrying ' + $inner.Length + ' chars of prose') }
  }
  return $bad
}

# Gold means money. This catches the drift where gold quietly becomes a heading color: it flags gold used
# as a text color on an element whose class says "head"/"title"/"label" and carries no money marker.
function Test-TcGoldDiscipline {
  param([Parameter(Mandatory=$true)][string]$Html)
  $bad = @()
  # money gold as the text color of a heading element, or of anything whose class calls itself a head/title/label
  foreach ($m in [regex]::Matches($Html, "(?i)<h[1-6][^>]*style=['""][^'""]*color:\s*#e2a43c")) {
    $bad += ('gold used as a heading color: ' + $m.Value.Substring(0, [math]::Min(120, $m.Value.Length)))
  }
  foreach ($m in [regex]::Matches($Html, "(?i)<[a-z0-9]+[^>]*class=['""][^'""]*(head|cath|title|label)[^'""]*['""][^>]*style=['""][^'""]*color:\s*#e2a43c")) {
    $bad += ('gold used as a heading color: ' + $m.Value.Substring(0, [math]::Min(120, $m.Value.Length)))
  }
  return $bad
}

# One print block for the whole site: nav, CTAs and every floating thing disappear; receipts, checked
# state and dotted leaders survive. Added to the per-wave verification checklist so it cannot rot.
function Get-TcPrintCss {
@'
@media print{
  .tc-bar,.tc-transient,.tc-mode,.gh-navigation,.gh-header,.site-nav,.gh-foot,.pg-tripbar,.smp-mini,
  .mts-join-pop,#mts-join-pop,.pg-capture,.pg-cta,.mpr-cta,.mp2-offer,.mp2-hero,.smprrf-card,
  .tc-noprint,[data-portal]{display:none!important}
  .tc-receipt{box-shadow:none!important;border:1px solid #999!important;background:#fff!important}
  .tc-receipt::before,.tc-receipt::after{display:none!important}
  .tc-lead{border-bottom:1px dotted #999!important}
  .tc-ck input{opacity:1!important;position:static!important;width:13px;height:13px;-webkit-appearance:checkbox;appearance:checkbox}
  .tc-ck .tc-ck-box,.tc-ck svg{display:none!important}
  .tc-navy,.tc-navy-grad{background:#fff!important;color:#000!important;border:1px solid #999!important}
  .tc-navy .tc-h,.tc-navy .tc-title,.tc-navy .tc-dek,.tc-navy .tc-eyebrow{color:#000!important}
  a[href]:after{content:''!important}
  body{background:#fff!important}
}
'@
}
