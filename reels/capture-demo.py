"""
capture-demo.py - photograph the LIVE recipe page while actually using it.

WHY THIS IS SEPARATE FROM build-reel.ps1
  The daily reel renders scenes it authors itself from JSON, so nothing it shows can drift from the
  site: there is no site in the picture. A product demo is the opposite. Its entire claim is "this is
  what the page does", so the frames have to come from the page, driven the way a reader drives it:
  tap the stepper, switch the cost tabs, untick what you already own. Anything mocked up here would
  be a lie the moment the card changes, and this estate has already learned that a plausible wrong
  screenshot is worse than no screenshot.

WHAT IT DOES
  Drives thriftycrew.com in headless Chrome over CDP (cdp.py), captures a PNG per beat, and writes
  demo-manifest.json holding BOTH the frame list and every number that appears in those frames. The
  voiceover is written from that manifest, never from a human's memory of the page, so the words and
  the pixels cannot disagree. If the widget renders a different total tomorrow, the narration changes
  with it.

  Numbers are READ, never computed. The unticked total is whatever the widget says after the clicks,
  because the widget is the thing being demonstrated. Recomputing it here would be inventing a second
  source of truth for the exact number the video is claiming.

USAGE
  python capture-demo.py                       # this week's #1 free recipe
  python capture-demo.py --slug chicken-fried-rice-skillet
  python capture-demo.py --out <dir> --keep    # leave frames in place for inspection
"""
import argparse
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import Chrome

SITE = "https://www.thriftycrew.com"
INCOME = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FREE_ROTATION = os.path.join(INCOME, "meal-prep", "free-rotation.json")

# The reel frame gives the screen a 1080x1250 window (see build-demo-reel.ps1 for the layout: slim
# masthead on top, caption band under it, and 300px of dead space at the bottom that Facebook's own
# UI sits over). At 2.88x that window is a 375x434 CSS phone. 375 wide is the mobile-first width the
# whole site is verified at; the height is simply what is left after the frame takes its share.
#
# It matters that the capture is exactly the window and not a pixel taller. Capture more than the
# frame shows and the demo starts hiding its own subject: the floating servings bar is anchored to
# the bottom of the viewport, so any overhang puts the control being demonstrated off screen.
CSS_W, CSS_H, DSF = 375, 434, 2.88

# Things a reader plausibly already owns. Conservative on purpose: unticking the chicken would make
# the drop look impressive and the demo dishonest. Fresh produce and the protein stay ticked.
PANTRY = [
    "salt", "black pepper", "pepper", "soy sauce", "brown sugar", "granulated sugar",
    "sesame oil", "olive oil", "vegetable oil", "canola oil", "cooking spray",
    "flour", "cornstarch", "vinegar", "paprika", "cumin", "chili powder", "oregano",
    "italian seasoning", "garlic powder", "onion powder", "cinnamon", "five-spice",
    "red pepper flake", "bay leaf", "thyme", "basil", "curry powder", "honey",
]
MAX_UNTICK = 5

# Suppress the site-wide join interstitial. On a free-rotation recipe page it shows to EVERYONE
# including first-time visitors (that is its whole design), so it would land on top of the demo.
# Belt and braces: pre-set the session flag it honours, AND hide the overlay outright, because the
# flag semantics are the interstitial's business and may change without this script hearing about it.
SUPPRESS = r"""
try{
  sessionStorage.setItem('tc_ji_sess','1');
  localStorage.setItem('tc_seen','1');
  localStorage.setItem('tc_ji_until', String(Date.now()+8.64e8));
  /* Answer the cookie banner the privacy-preserving way rather than letting it sit over the demo.
     'declined' is the site's own value for essential-only, so the capture session opts out of
     analytics instead of quietly accepting on a reader's behalf. */
  localStorage.setItem('smp_cookie_consent','declined');
}catch(e){}
(function add(){
  if(!document.head){ return setTimeout(add,10); }
  var s=document.createElement('style');
  s.id='tc-demo-suppress';
  s.textContent='.tcji-ov,.tcji-pop,#smp-cc{display:none!important}';
  document.head.appendChild(s);
})();
"""

# A tap the viewer can see. The ring is drawn where the element actually is, measured at capture
# time, so it cannot drift off the control it is pointing at when the card's layout changes.
TAP_HELPERS = r"""
window.__tcRing = function(sel, nth){
  window.__tcRingClear();
  var els = document.querySelectorAll(sel);
  var el = els[nth||0];
  if(!el) return false;
  var r = el.getBoundingClientRect();
  var d = document.createElement('div');
  d.className = '__tcring';
  d.style.cssText = 'position:fixed;z-index:2147483000;pointer-events:none;border-radius:'
    + (r.height > 46 ? '14px' : '999px')
    + ';border:4px solid #E4B549;box-shadow:0 0 0 6px rgba(228,181,73,.28);'
    + 'left:' + (r.left-7) + 'px;top:' + (r.top-7) + 'px;'
    + 'width:' + (r.width+14) + 'px;height:' + (r.height+14) + 'px;';
  document.body.appendChild(d);
  return true;
};
window.__tcRingClear = function(){
  document.querySelectorAll('.__tcring').forEach(function(n){ n.remove(); });
};
window.__tcTxt = function(sel){
  var e = document.querySelector(sel);
  return e ? e.innerText.replace(/\s+/g,' ').trim() : '';
};
window.__tcHideFixed = function(on){
  /* Sticky and fixed furniture (site header, the floating servings bar) is real and belongs in the
     interaction shots, but it is nonsense in a tall clip capture: the browser paints it once,
     wherever it happened to be, and it lands across the middle of the image. Hidden by COMPUTED
     position rather than by selector so a theme change cannot quietly reintroduce it. */
  document.querySelectorAll('body *').forEach(function(e){
    var p = getComputedStyle(e).position;
    if(p !== 'fixed' && p !== 'sticky') return;
    if(on){ e.setAttribute('data-tcvis', e.style.visibility || ''); e.style.visibility = 'hidden'; }
    else  { e.style.visibility = e.getAttribute('data-tcvis') || ''; e.removeAttribute('data-tcvis'); }
  });
  return true;
};
window.__tcStill = function(){
  /* Freeze anything mid-transition so a frame never catches a half-drawn control. */
  var s = document.getElementById('tc-demo-still');
  if(s) return true;
  s = document.createElement('style');
  s.id = 'tc-demo-still';
  s.textContent = '*,*::before,*::after{transition-duration:0s!important;animation-duration:0s!important}';
  document.head.appendChild(s);
  return true;
};
window.__tcScrubLocation = function(){
  /* Pinned social copy is deliberately geography-neutral. The live pages keep their local proof,
     but the pinned capture must not let a source note or tiny price stamp narrow the audience after
     the narration and cards worked so hard not to. Touch visible text nodes only; scripts and data
     remain byte-for-byte what the live page shipped. */
  var w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,{acceptNode:function(n){
    var p=n.parentElement, tag=p&&p.tagName;
    if(!p||tag==='SCRIPT'||tag==='STYLE'||tag==='NOSCRIPT') return NodeFilter.FILTER_REJECT;
    return /omaha/i.test(n.nodeValue||'')?NodeFilter.FILTER_ACCEPT:NodeFilter.FILTER_REJECT;
  }});
  var hit=[],n;while((n=w.nextNode()))hit.push(n);
  hit.forEach(function(t){t.nodeValue=t.nodeValue.replace(/omaha/ig,'local');});
  return hit.length;
};
"""


def money(text):
    m = re.search(r"\$[0-9][0-9,]*\.[0-9]{2}", text or "")
    return m.group(0) if m else ""


def load_free_slug(slug_arg):
    with open(FREE_ROTATION, encoding="utf-8-sig") as fh:
        rot = json.load(fh)
    free = rot.get("free") or []
    if slug_arg:
        for f in free:
            if f["slug"] == slug_arg:
                return slug_arg, rot.get("week_of"), True
        # A paid recipe is allowed but the CTA must not promise a free page, so say so out loud.
        return slug_arg, rot.get("week_of"), False
    if not free:
        raise RuntimeError("free-rotation.json lists no free recipes")
    return free[0]["slug"], rot.get("week_of"), True


class Capture:
    def __init__(self, chrome, outdir, scrub_location=False):
        self.c = chrome
        self.outdir = outdir
        self.n = 0
        self.scrub_location = scrub_location

    def frame(self, scene, tag=""):
        if self.scrub_location:
            self.c.js("window.__tcScrubLocation()")
        self.n += 1
        name = "%s-%02d%s.png" % (scene, self.n, ("-" + tag) if tag else "")
        path = os.path.join(self.outdir, name)
        self.c.shot(path)
        return path

    def scroll_to(self, sel, offset=-72, settle=0.6):
        """Put an element at a known place in the window. Real scrolling, not a clipped capture, so
        the sticky header and the floating servings bar sit exactly where a reader sees them.

        Scrolled in steps, and that is load-bearing, not cosmetic. Headless Chrome only runs
        IntersectionObserver callbacks when it produces frames, so a single jump scroll moves the
        page without ever telling the observers, and the floating servings bar (which is driven by
        one) stays hidden. A stepped scroll makes the browser draw, the observer fires, and the
        capture shows the control the site actually puts in front of a reader."""
        y = self.c.js(
            "(function(){var e=document.querySelector(%s);if(!e)return null;"
            "var r=e.getBoundingClientRect();return Math.max(0,Math.round(r.top+window.scrollY+(%d)));})()"
            % (json.dumps(sel), offset))
        if y is None:
            raise RuntimeError("scroll target not found: " + sel)
        start = self.c.js("window.scrollY") or 0
        steps = 12
        for k in range(1, steps + 1):
            self.c.js("window.scrollTo(0,%d)" % (start + (y - start) * k // steps))
            time.sleep(0.06)
        time.sleep(settle)
        return y


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--slug")
    ap.add_argument("--out", required=True)
    ap.add_argument("--small-servings", type=int, default=6)
    ap.add_argument("--overview", action="store_true",
                    help="also capture the meal-prep hub, cooking finish, and grocery search for the pinned overview reel")
    ap.add_argument("--head", action="store_true", help="run headed, for watching it work")
    args = ap.parse_args()

    slug, week_of, is_free = load_free_slug(args.slug)
    url = "%s/%s/" % (SITE, slug)
    os.makedirs(args.out, exist_ok=True)

    facts = {"slug": slug, "url": url, "week_of": week_of, "is_free": is_free}
    scenes = []

    with Chrome(headless=not args.head, width=CSS_W, height=CSS_H, dsf=DSF) as c:
        c.on_new_document(SUPPRESS)
        c.on_new_document(TAP_HELPERS)
        c.goto(url, wait_ms=1500)
        c.js("window.__tcStill()")

        # The cost widget paints everyday prices first, then rewrites itself when the live feed
        # lands. Photographing it before that is how you ship a video quoting last month's price.
        c.wait_for("!!document.querySelector('.smp-cp-total')", timeout=25, label="cost widget")
        c.wait_for("(window.__tcTxt('.smp-cp-total')||'').indexOf('$')>-1", timeout=25,
                   label="a total with a price in it")
        time.sleep(1.2)

        cap = Capture(c, args.out, scrub_location=args.overview)

        facts["name"] = c.js("document.querySelector('h1').innerText.trim()")
        facts["stat_line"] = c.js("window.__tcTxt('.smp-stat')")
        facts["ct_save"] = c.js("window.__tcTxt('.smp-ct-save')")
        facts["ct_sub"] = c.js("window.__tcTxt('.smp-ct-sub')")
        facts["servings"] = int(c.js("document.querySelector('.smp-sc-num').value") or 14)

        m = re.search(r"(\d+)\s*g protein", facts["stat_line"] or "")
        facts["protein_g"] = int(m.group(1)) if m else None
        m = re.search(r"~?([\d,]+)\s*cal", facts["stat_line"] or "")
        facts["calories"] = int(m.group(1).replace(",", "")) if m else None

        # ---------------------------------------------------------------- 1. the page itself
        # A tall capture panned in ffmpeg, rather than a stack of stills: this beat is pure motion,
        # and 30fps of pan reads as scrolling where 8 stills read as a slideshow.
        #
        # Warm the page first. Images below the fold are lazy, and a clip capture does not count as
        # scrolling them into view, so an unwarmed capture photographs the reserved empty boxes and
        # the reel opens on a blank white rectangle where the food should be.
        doc_h = c.js("document.documentElement.scrollHeight")
        for k in range(1, 15):
            c.js("window.scrollTo(0,%d)" % (doc_h * k // 14))
            time.sleep(0.09)
        c.js("window.scrollTo(0,0)")
        c.wait_for("[].every.call(document.images,function(i){return !i.loading||i.loading!=='lazy'"
                   "||i.complete;})", timeout=15, label="lazy images")
        time.sleep(0.8)
        if args.overview:
            c.js("window.__tcScrubLocation()")

        top_y = c.js("(function(){var e=document.querySelector('h1');"
                     "return Math.round(e.getBoundingClientRect().top+window.scrollY-24);})()")
        pan_h = 900   # CSS px of page in one image; the window shows 486 of it at a time
        c.js("window.__tcHideFixed(true)")
        intro_png = os.path.join(args.out, "intro-pan.png")
        c.shot(intro_png, clip=(0, top_y, CSS_W, pan_h))
        c.js("window.__tcHideFixed(false)")
        scenes.append({"id": "intro", "kind": "pan", "png": intro_png,
                       "src_h_css": pan_h, "win_h_css": CSS_H})

        if args.overview:
            # The ordinary demo stops at the shopping math. The pinned overview needs to finish the
            # customer's journey: cook it, portion it, and understand that the page is a complete
            # plan rather than a price widget attached to a recipe.
            for scene_id, heading in (("cook", "Make It"), ("portion", "Portion It")):
                marker = "data-tc-demo-section"
                found = c.js(
                    "(function(){var want=%s;var hs=[].slice.call(document.querySelectorAll('h2'));"
                    "var h=hs.find(function(x){return x.textContent.trim()===want;});"
                    "if(!h)return false;h.setAttribute(%s,%s);return true;})()"
                    % (json.dumps(heading), json.dumps(marker), json.dumps(scene_id)))
                if not found:
                    raise RuntimeError("recipe section not found: " + heading)
                sel = '[%s="%s"]' % (marker, scene_id)
                cap.scroll_to(sel, offset=-20, settle=0.6)
                scenes.append({"id": scene_id, "kind": "frames", "frames": [
                    {"png": cap.frame(scene_id, "section"), "hold": 3.0}
                ]})

        # ---------------------------------------------------------------- 2. make it your size
        # Framed on the ingredient list, not the stepper box: the point is that the LIST rewrites.
        # The floating servings bar is the control the site itself puts here for exactly this.
        cap.scroll_to(".smp-ing", offset=-96)
        c.wait_for("!!document.querySelector('.smp-mini.is-on')", timeout=8,
                   label="the floating servings bar")
        facts["ing_before"] = c.js(
            "[].map.call(document.querySelectorAll('.smp-ing li'),"
            "function(l){return l.innerText.replace(/\\s+/g,' ').trim();}).slice(0,6)")

        frames = []
        c.js("window.__tcRing('.smp-mini-dn')")
        frames.append({"png": cap.frame("size", "start"), "hold": 1.5})

        target = max(2, args.small_servings)
        steps, guard = [], 0
        while True:
            cur = int(c.js("document.querySelector('.smp-sc-num').value") or 0)
            if cur <= target or guard > 40:
                break
            c.js("document.querySelector('.smp-mini-dn').click()")
            guard += 1
            time.sleep(0.28)
            now = int(c.js("document.querySelector('.smp-sc-num').value") or 0)
            if now == cur:
                raise RuntimeError("the servings stepper did not move on click")
            steps.append(now)
            if now <= target or now % 2 == 0:
                c.js("window.__tcRing('.smp-mini-dn')")
                frames.append({"png": cap.frame("size", "n%d" % now), "hold": 0.30})
        c.js("window.__tcRingClear()")
        time.sleep(0.5)
        frames.append({"png": cap.frame("size", "held"), "hold": 2.2})

        facts["small_servings"] = int(c.js("document.querySelector('.smp-sc-num').value"))
        facts["ing_after"] = c.js(
            "[].map.call(document.querySelectorAll('.smp-ing li'),"
            "function(l){return l.innerText.replace(/\\s+/g,' ').trim();}).slice(0,6)")
        facts["small_total"] = money(c.js("window.__tcTxt('.smp-cp-total')"))
        scenes.append({"id": "size", "kind": "frames", "frames": frames})

        # Back to the recipe's own batch size for the cost beats. A cost section demonstrated at six
        # servings would quote a total that no other surface on the site agrees with.
        c.js("var i=document.querySelector('.smp-sc-num');i.value=%d;"
             "i.dispatchEvent(new Event('input',{bubbles:true}));"
             "i.dispatchEvent(new Event('change',{bubbles:true}));" % facts["servings"])
        time.sleep(0.8)
        back = int(c.js("document.querySelector('.smp-sc-num').value") or 0)
        if back != facts["servings"]:
            raise RuntimeError("could not restore servings to %d (got %d)" % (facts["servings"], back))

        # ---------------------------------------------------------------- 3. what this costs
        cap.scroll_to(".smp-ct-btns", offset=-84)
        time.sleep(0.6)
        facts["tabs"] = c.js(
            "[].map.call(document.querySelectorAll('.smp-ct-btn'),"
            "function(b){return {t:b.getAttribute('data-t'),label:b.textContent.trim()};})")
        facts["total_line"] = c.js("window.__tcTxt('.smp-cp-total')")
        facts["total"] = money(facts["total_line"])
        m = re.search(r"about (\$[\d.]+) a serving", facts["total_line"] or "")
        facts["per_serving"] = m.group(1) if m else ""

        # ---------------------------------------------------------------- 4. the three tabs
        tab_frames, tab_totals = [], {}
        for i, tab in enumerate(facts["tabs"]):
            c.js("window.__tcRing('.smp-ct-btn', %d)" % i)
            c.js("document.querySelectorAll('.smp-ct-btn')[%d].click()" % i)
            time.sleep(0.7)
            on = c.js("document.querySelectorAll('.smp-ct-btn')[%d].classList.contains('on')" % i)
            if not on:
                raise RuntimeError("cost tab %s did not activate" % tab["t"])
            line = c.js("window.__tcTxt('.smp-cp-total')")
            tab_totals[tab["t"]] = {"line": line, "total": money(line)}
            tab_frames.append({"png": cap.frame("tabs", tab["t"]), "hold": 1.9})
        facts["tab_totals"] = tab_totals
        c.js("window.__tcRingClear()")

        # ---------------------------------------------------------------- 4b. the totals themselves
        # The tab buttons and the total are ~950 CSS px apart, so no single frame holds both. The
        # comparison the narration makes ("everyday versus cheapest") has to be SEEN, or the video is
        # asserting a number the viewer never saw. Second pass, framed on the total, switching tabs
        # off-screen so only the figure moves.
        totals_frames = []
        for want in ("everyday", "cheapest"):
            idx = next(i for i, t in enumerate(facts["tabs"]) if t["t"] == want)
            c.js("document.querySelectorAll('.smp-ct-btn')[%d].click()" % idx)
            time.sleep(0.7)
            cap.scroll_to(".smp-cp-total", offset=-int(CSS_H * 0.55), settle=0.5)
            line = c.js("window.__tcTxt('.smp-cp-total')")
            if money(line) != tab_totals[want]["total"]:
                raise RuntimeError("tab %s total moved between passes (%s vs %s)"
                                   % (want, line, tab_totals[want]["line"]))
            totals_frames.append({"png": cap.frame("totals", want), "hold": 2.4})

        # ---------------------------------------------------------------- 5. untick what you own
        c.js("document.querySelectorAll('.smp-ct-btn')[0].click()")
        time.sleep(0.7)
        cap.scroll_to(".smp-ct-list", offset=-84)
        time.sleep(0.4)

        rows = c.js(
            "[].map.call(document.querySelectorAll('.smp-ct-list li'),function(li,i){"
            "var ck=li.querySelector('input[type=checkbox]');"
            "var lb=li.querySelector('.smp-ct-ck');"
            "return {i:i,txt:li.innerText.replace(/\\s+/g,' ').trim(),ck:!!ck,"
            "name:lb?lb.innerText.replace(/\\s+/g,' ').trim():''};})")
        picks = []
        for r in rows:
            if not r["ck"]:
                continue
            low = (r["name"] or r["txt"]).lower()
            if any(p in low for p in PANTRY):
                picks.append({"i": r["i"], "name": r["name"] or r["txt"].split("$")[0].strip(),
                              "price": money(r["txt"])})
            if len(picks) >= MAX_UNTICK:
                break
        if not picks:
            raise RuntimeError("no pantry staples found to untick; check the PANTRY list")

        untick_frames = [{"png": cap.frame("untick", "before"), "hold": 1.6}]
        for p in picks:
            # Scroll the row into the window before ringing it, or the ring lands off-frame on a
            # long list. Then click the checkbox itself, the way a reader would.
            c.js("document.querySelectorAll('.smp-ct-list li')[%d]"
                 ".scrollIntoView({block:'center',behavior:'instant'})" % p["i"])
            time.sleep(0.25)
            c.js("window.__tcRing('.smp-ct-list li input[type=checkbox]', %d)" % _ck_index(rows, p["i"]))
            c.js("document.querySelectorAll('.smp-ct-list li')[%d]"
                 ".querySelector('input[type=checkbox]').click()" % p["i"])
            time.sleep(0.45)
            still_on = c.js("document.querySelectorAll('.smp-ct-list li')[%d]"
                            ".querySelector('input[type=checkbox]').checked" % p["i"])
            if still_on:
                raise RuntimeError("unticking %s did nothing" % p["name"])
            untick_frames.append({"png": cap.frame("untick", "off%d" % p["i"]), "hold": 0.85})
        c.js("window.__tcRingClear()")

        cap.scroll_to(".smp-cp-total", offset=-int(CSS_H * 0.55))
        time.sleep(0.6)
        facts["untick_total_line"] = c.js("window.__tcTxt('.smp-cp-total')")
        facts["untick_total"] = money(facts["untick_total_line"])
        facts["unticked"] = picks
        # The card prints its own "already in your kitchen" subtotal. Read it rather than adding the
        # unticked prices up here: the widget owns that arithmetic, and two sources for one figure on
        # screen is exactly how a video ends up contradicting the page it is demonstrating.
        facts["kitchen_line"] = c.js(
            "(function(){var hit='';document.querySelectorAll('.smp-ct *').forEach(function(e){"
            "if(hit)return;var t=(e.innerText||'');"
            "if(/already in your kitchen/i.test(t)&&e.children.length===0)hit=t;});"
            "return hit.replace(/\\s+/g,' ').trim();})()")
        facts["kitchen_total"] = money(facts["kitchen_line"])
        untick_frames.append({"png": cap.frame("untick", "after"), "hold": 2.6})

        if not facts["untick_total"] or facts["untick_total"] == facts["total"]:
            raise RuntimeError("the total did not move after unticking %d items" % len(picks))

        scenes.append({"id": "tabs", "kind": "frames", "frames": tab_frames})
        scenes.append({"id": "totals", "kind": "frames", "frames": totals_frames})
        scenes.append({"id": "untick", "kind": "frames", "frames": untick_frames})

        if args.overview:
            # Show the library as the actual starting point. Two frames give the viewer both halves
            # of the promise: free choices up front, then search/filter controls for the full catalog.
            c.goto(SITE + "/meal-prep-recipes/", wait_ms=1800)
            c.js("window.__tcStill()")
            c.wait_for("document.querySelectorAll('.mpr-card').length>10", timeout=25,
                       label="the meal-prep recipe library")
            time.sleep(0.9)
            hub_frames = []
            cap.scroll_to(".mpr-rail-wrap", offset=-14, settle=0.6)
            hub_frames.append({"png": cap.frame("hub", "free"), "hold": 2.4})
            cap.scroll_to(".mpr-filters", offset=-14, settle=0.6)
            hub_frames.append({"png": cap.frame("hub", "filters"), "hold": 2.8})
            scenes.append({"id": "hub", "kind": "frames", "frames": hub_frames})
            facts["hub_recipe_count"] = int(c.js("document.querySelectorAll('.mpr-grid .mpr-card').length") or 0)

            # The grocery page is intentionally a light handoff. Capture the working search and
            # rows, not the geographic page heading. Copy in the reel never names the city, and the
            # useful part for this story is simply that current store prices are searchable.
            c.goto(SITE + "/omaha-grocery-prices/", wait_ms=2000)
            c.js("window.__tcStill()")
            c.wait_for("document.querySelectorAll('.pg-row').length>10", timeout=30,
                       label="the grocery price rows")
            time.sleep(1.0)
            cap.scroll_to(".pg-filters", offset=0, settle=0.7)
            c.js("(function(){var q=document.getElementById('pg-search');q.value='chicken';"
                 "q.dispatchEvent(new Event('input',{bubbles:true}));return true;})()")
            time.sleep(0.8)
            grocery_text = c.js(
                "[].map.call(document.querySelectorAll('.pg-row:not(.pg-hide) .pg-name'),"
                "function(e){return e.textContent.trim();}).slice(0,5)")
            if not grocery_text:
                raise RuntimeError("the grocery search produced no visible rows")
            scenes.append({"id": "grocery", "kind": "frames", "frames": [
                {"png": cap.frame("grocery", "search"), "hold": 3.2}
            ]})
            facts["grocery_search"] = "chicken"
            facts["grocery_results"] = grocery_text

    facts["captured_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    manifest = {"facts": facts, "scenes": scenes,
                "window": {"w": int(CSS_W * DSF), "h": int(round(CSS_H * DSF)),
                           "css_w": CSS_W, "css_h": CSS_H, "dsf": DSF}}
    mpath = os.path.join(args.out, "demo-manifest.json")
    with open(mpath, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2)
    print(mpath)


def _ck_index(rows, li_index):
    """Index of a row's checkbox among ALL checkboxes in the list (the ring selector is flat)."""
    n = 0
    for r in rows:
        if r["i"] == li_index:
            return n
        if r["ck"]:
            n += 1
    return 0


if __name__ == "__main__":
    main()
