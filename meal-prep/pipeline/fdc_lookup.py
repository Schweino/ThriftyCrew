"""fdc_lookup.py - candidate nutrition rows from USDA FoodData Central. Mechanical, no model.

WHY THIS EXISTS (2026-08-24). The mapper WebFetches 9-10 nutrition labels per singleton dispatch, and
every fetched page then rides in its conversation for each later round trip - that is the quadratic
cost term measured on the 6b run, where a one-recipe mapper batch billed 436,685 and 577,141 tokens.

AND 58 FOOD-DB ROWS ALREADY CAME FROM FDC, fetched ad hoc by an agent with no versioned tool behind it
("fetched from FDC portal API 2026-07-25; Atwater 181 vs 186 ok"). So the estate already trusted this
source; it simply never had a client. This is that client.

WHY A DATABASE BEATS TRANSCRIBING A PAGE. B8 built a road for reading a printed nutrition panel out of
page text, substring-proven. That road is right when a panel is all you have. It is strictly worse than
asking a government database that returns the numbers AS DATA - there is nothing to transcribe, nothing
to prove, and no window to size. Qwen transcription stays for what FDC does not carry: branded and
regional products.

WHERE THE DOCTRINE PUTS THE SPLIT (section 1.4). Fetching candidate rows is mechanical. Deciding WHICH
row is the food - "Parsley, fresh" against "Parsley, dried" against a branded parsley product - is an
identity assertion, measured at 37% false locally, so it stays frontier. This module gathers and ranks;
it never rules. `search` returns candidates in FDC's own relevance order with their numbers attached,
and the mapper picks.

THE KEY IS NEVER STORED HERE. It is read from FDC_API_KEY in the environment, or from the path in
FDC_KEY_FILE, or from meal-prep\db\fdc-api-key.txt. Absent, every entry point returns a CANNOT-RUN
result naming exactly where to put one. A key is a credential and this file must not become the place
one lives.
"""
from __future__ import annotations

import json
import os
import re
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
MP = os.path.dirname(HERE)
KEY_FILE = os.path.join(MP, "db", "fdc-api-key.txt")
SEARCH_URL = "https://api.nal.usda.gov/fdc/v1/foods/search"

# The four the food DB actually stores. FDC names them verbatim like this.
WANT = {
    "Energy": "calories",
    "Protein": "protein_g",
    "Carbohydrate, by difference": "carbs_g",
    "Total lipid (fat)": "fat_g",
    # FIBRE IS NOT A MACRO THE FOOD DB STORES, it is carried because the Atwater check is WRONG
    # without it - see atwater_check.
    "Fiber, total dietary": "fiber_g",
}

# SR Legacy and Foundation are whole-food reference entries; Branded carries retail products with
# their own label. Survey (FNDDS) entries are recipe-like composites and are a poor basis for a
# per-ingredient row, so they are not requested.
DEFAULT_TYPES = ("SR Legacy", "Foundation", "Branded")

# See atwater_check: below this, a ratio says nothing.
ABS_TOLERANCE_KCAL = 20.0

# ETHANOL IS 7 kcal/g AND IT IS NONE OF PROTEIN, CARB OR FAT, so 4/4/9 cannot see it. Measured on
# the live DB 2026-08-26: Red Wine states 85 cal against 0.1 P / 2.6 C / 0 F, which computes 11 - an
# 87% gap on a row that is exactly right. Dry White Wine (82 vs 11) and Marsala (152 vs 48) are the
# same arithmetic, and the run they blocked published nothing. This is the SAME SHAPE as the fibre
# term already above: a real energy carrier the general factors omit, credited as a fourth term.
KCAL_PER_G_ALCOHOL = 7.0

# WHAT THE FOURTH TERM IS NOT: an exemption. Crediting the residual to ethanol with no further test
# would pass ANY four numbers for anything named "wine", which is the gate turned off for a whole
# class of foods. So the residual has to land where that class's ethanol actually lands. The bands
# are grams of ethanol per 100 g of the food AS SOLD - ABV is by VOLUME, so a 12.5% ABV wine carries
# 0.125 * 0.789 / 0.99 = ~10 g per 100 g, not 12.5. Bands are deliberately wider than the real
# spread; they exist to refuse a fabrication, not to grade a vintage.
#   Checked against the estate's own rows the day this was written:
#     Red Wine        residual 74.0 -> 10.6 g/100 g   (12.5% ABV table wine is ~10)
#     Dry White Wine  residual 71.0 -> 10.1 g/100 g   (11.5% ABV is ~9.2)
#     Marsala Wine    residual 104.4 -> 14.9 g/100 g  (18% ABV fortified is ~14.2)
#     USDA 80-proof spirits  231 -> 33.0 g/100 g      (40% ABV is ~33)
#     USDA regular beer       27 -> 3.9 g/100 g       (4.5% ABV is ~3.6)
#     USDA vanilla extract   236.6 -> 33.8 g/100 g    (35% ABV is ~30)
ALCOHOL_BANDS = (
    # (class name, (min g/100 g, max g/100 g))
    ("spirit",          (22.0, 52.0)),
    ("extract",         (22.0, 95.0)),
    ("fortified wine",  (8.0,  24.0)),
    ("wine",            (2.0,  18.0)),
    ("beer",            (0.5,  12.0)),
)

# A NAME IS THE ONLY SIGNAL A ROW CARRIES, so the matcher is explicit on both sides. The exclusions
# are not tidiness: the live DB holds Red Wine Vinegar, White Wine Vinegar and Rice Vinegar, all of
# which say "wine" and none of which carry drinkable ethanol - a vinegar handed the wine band would
# be a row this check waved through on a word.
_ALCOHOL_NOT = re.compile(
    r"(?i)\b(vinegar|root beer|ginger beer|birch beer|non[- ]?alcoholic|alcohol[- ]?free|"
    r"de[- ]?alcoholi[sz]ed|0\.0%|near beer)\b")
_ALCOHOL_CLASS = (
    ("spirit", re.compile(
        r"(?i)\b(vodka|gin|rum|whisk(?:e)?y|bourbon|tequila|brandy|cognac|scotch|"
        r"grappa|schnapps|absinthe|mezcal|liqueur|triple sec|kirsch)\b")),
    ("extract", re.compile(r"(?i)\bextract\b")),
    ("fortified wine", re.compile(
        r"(?i)\b(marsala|sherry|port wine|madeira|vermouth|fortified wine|dessert wine)\b")),
    ("wine", re.compile(r"(?i)\b(wine|sake|saké|mirin|shaoxing|prosecco|champagne|riesling|"
                        r"chardonnay|merlot|cabernet|pinot|sangria)\b")),
    ("beer", re.compile(r"(?i)\b(beer|ale|lager|stout|porter|pilsner|hard cider|hard seltzer)\b")),
)


def alcohol_class(name):
    """The class an item name declares, or None. Name-only by design - a food-DB row carries no ABV
    field, and inventing one from the macros would be the circularity this check exists to break."""
    n = str(name or "")
    if not n.strip() or _ALCOHOL_NOT.search(n):
        return None
    for cls, rx in _ALCOHOL_CLASS:
        if rx.search(n):
            return cls
    return None


def api_key():
    """The key, or None. Never written, never logged, never defaulted to DEMO_KEY - a demo key that
    silently throttles looks like 'FDC has no data for this food', which is the worst possible lie for
    a nutrition lookup to tell."""
    k = os.environ.get("FDC_API_KEY", "").strip()
    if k:
        return k
    path = os.environ.get("FDC_KEY_FILE", "").strip() or KEY_FILE
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            k = f.read().strip()
        return k or None
    except Exception:                                             # noqa: BLE001
        return None


def _blocked():
    return {"ok": False, "why": ("no FDC API key. Put one in FDC_API_KEY, or in the file named by "
                                 "FDC_KEY_FILE, or at %s. It is free and instant from api.data.gov, "
                                 "and nothing here stores it." % KEY_FILE),
            "candidates": []}


def _macros(food):
    """The four macros, per 100 g, from an FDC food record. Energy in kJ is IGNORED rather than
    converted: FDC returns BOTH KCAL and KJ rows for the same food and taking whichever came first
    would silently store 151 where 36 belongs."""
    out = {}
    for n in (food.get("foodNutrients") or []):
        name = str(n.get("nutrientName") or "")
        field = WANT.get(name)
        if not field:
            continue
        unit = str(n.get("unitName") or "").upper()
        if field == "calories" and unit != "KCAL":
            continue
        val = n.get("value")
        if isinstance(val, (int, float)) and field not in out:
            out[field] = float(val)
    return out


def _portions(food):
    """Household measures FDC states for this food, if any. The food DB wants a serving in BOTH a
    household measure and grams, and FDC carries portions for many foods but not all - so this
    returns what exists and never invents one."""
    out = []
    for p in (food.get("foodPortions") or []):
        desc = str(p.get("portionDescription") or p.get("modifier") or "").strip()
        grams = p.get("gramWeight")
        if desc and isinstance(grams, (int, float)):
            out.append({"measure": desc, "grams": float(grams)})
    return out[:6]


def search(term, page_size=5, data_types=None, opener=None, key=None):
    """CURATED FIRST, BRANDED ONLY IF NOTHING CURATED EXISTS.

    Ranking alone was not enough, and the cache showed it: asking FDC for "parsley" returns three
    Branded rows reading 0.0 cal / 0.0 P / 0.0 C, and no amount of sorting promotes an SR Legacy row
    that was never in the reply. Querying "parsley, fresh" HAD returned the good row - so the problem
    was the question, not the order.

    Two stages: SR Legacy and Foundation first, which are curated whole-food entries with real
    numbers, and Branded only when those come back empty. That costs a second call only for foods the
    reference set does not carry, which is exactly where a retail label is the best available answer.
    An explicit `data_types` overrides both stages, so a caller can still ask for one tier.
    """
    if data_types is not None:
        return _search_one(term, page_size, data_types, opener, key)
    first = _search_one(term, page_size, ("SR Legacy", "Foundation"), opener, key)
    if not first.get("ok") or first["candidates"]:
        return first
    return _search_one(term, page_size, ("Branded",), opener, key)


def _search_one(term, page_size=5, data_types=DEFAULT_TYPES, opener=None, key=None):
    """CANDIDATE rows for one food, in FDC's own relevance order. Gathers; never rules.

    Returns {ok, why, candidates:[{fdc_id, description, data_type, brand, macros, portions}]}.
    """
    k = key or api_key()
    if not k:
        return _blocked()
    q = urllib.parse.urlencode({"query": term, "pageSize": max(1, min(int(page_size), 25)),
                                "dataType": ",".join(data_types), "api_key": k})
    url = SEARCH_URL + "?" + q
    try:
        if opener is not None:
            raw = opener(url)
        else:
            with urllib.request.urlopen(url, timeout=30) as resp:
                raw = resp.read().decode("utf-8", errors="replace")
        doc = json.loads(raw)
    except Exception as e:                                        # noqa: BLE001
        # A LOOKUP THAT COULD NOT RUN IS NOT A LOOKUP THAT FOUND NOTHING. Reporting a transport
        # failure as "no data" is the could-not-look-is-not-a-clean-bill shape, and for a nutrition
        # row it would send the mapper off to invent a label.
        return {"ok": False, "why": "FDC lookup failed: %s" % str(e)[:140], "candidates": []}
    cands = []
    for f in (doc.get("foods") or []):
        macros = _macros(f)
        if "calories" not in macros:
            continue
        cands.append({
            "fdc_id": f.get("fdcId"),
            "description": str(f.get("description") or "").strip(),
            "data_type": str(f.get("dataType") or "").strip(),
            "brand": str(f.get("brandOwner") or f.get("brandName") or "").strip() or None,
            "basis": "per 100 g",
            "macros": macros,
            "portions": _portions(f),
        })
    # RANK CURATED REFERENCE ROWS AHEAD OF BRANDED ONES. FDC's own relevance order puts Branded
    # first for a bare term, and Branded entries frequently carry all-zero macros - "PARSLEY
    # [Branded] per 100 g: 0.0 cal, 0.0 P, 0.0 C" was the first thing this cache served. SR Legacy
    # and Foundation are curated whole-food entries with real numbers; Branded is a retail label and
    # belongs behind them. A shelf of branded zeros is worse than an empty shelf.
    #
    # ZERO IS NOT AUTOMATICALLY JUNK - salt and water are honestly 0/0/0 - so nothing is DROPPED for
    # being zero. This only orders; the mapper still picks, and still sees everything.
    rank = {"SR Legacy": 0, "Foundation": 1, "Branded": 2}
    cands.sort(key=lambda c: (rank.get(c["data_type"], 3),
                              0 if any(v for v in c["macros"].values()) else 1))
    return {"ok": True, "why": "", "candidates": cands}


def atwater_check(macros, tolerance=0.15):
    """The estate's own verification move, from the row that passed it: 'Atwater 181 vs 186 ok'.
    4/4/9 over the macros must reproduce the stated calories. It CONFIRMS a row rather than correcting
    one - a mismatch means the four numbers do not describe one food, and the answer to that is to look
    again, never to overwrite the calories with the computed figure."""
    cal = macros.get("calories")
    p, c, f = macros.get("protein_g"), macros.get("carbs_g"), macros.get("fat_g")
    if not all(isinstance(x, (int, float)) for x in (cal, p, c, f)):
        return {"ok": False, "why": "not all four macros are present", "computed": None}
    # FIBRE YIELDS ~2 kcal/g, NOT 4, AND FDC's "carbohydrate, by difference" INCLUDES IT.
    # Measured on real FDC data the day this was written: parsley states 36 kcal with 2.97 P /
    # 6.33 C / 0.79 F, and plain 4/4/9 computes 44.3 - a 23% gap that failed a perfectly good row.
    # About half of parsley's carbohydrate is fibre; crediting it at 2 kcal/g reconciles to 37.7.
    # Widening the tolerance instead would have hidden the real mismatches this check exists to find.
    fib = macros.get("fiber_g")
    if isinstance(fib, (int, float)) and 0 <= fib <= c:
        computed = 4.0 * p + 4.0 * (c - fib) + 2.0 * fib + 9.0 * f
    else:
        computed = 4.0 * p + 4.0 * c + 9.0 * f
    # A NEAR-ZERO REFERENCE IS NOT A REFERENCE - the same rule map-preresolve states about sub-gram
    # weights, arriving here. Measured live the day this was built: monk fruit sweetener states 0 cal
    # (a legitimate zero-calorie sweetener, not a broken row) and cactus paddles state 5 cal where a
    # 7-kcal arithmetic difference reads as 140% drift. Relative tolerance is meaningless down there,
    # so an ABSOLUTE floor decides instead, and it is deliberately generous: this check exists to catch
    # a row whose four numbers describe DIFFERENT foods, which is an error of hundreds, not of seven.
    diff = abs(computed - cal)
    if diff <= ABS_TOLERANCE_KCAL:
        return {"ok": True, "computed": round(computed, 1), "drift": None,
                "why": "", "note": "within %d kcal absolute - too small a number to judge by ratio"
                                   % ABS_TOLERANCE_KCAL}
    if cal <= 0:
        return {"ok": False, "computed": round(computed, 1), "drift": None,
                "why": "stated 0 kcal but the macros compute %0.0f - one of them is wrong" % computed}
    drift = diff / float(cal)
    if drift <= tolerance:
        return {"ok": True, "computed": round(computed, 1), "drift": round(drift, 3), "why": ""}
    # THE FOURTH TERM, AND IT IS TRIED ONLY AFTER THE ORDINARY CHECK HAS ALREADY FAILED. A row whose
    # 4/4/9 reconciles never reaches here, so nothing that passes today changes answer.
    alc = _alcohol_reconciles(macros, computed, cal)
    if alc is not None:
        return alc
    return {"ok": False, "computed": round(computed, 1), "drift": round(drift, 3),
            "why": "Atwater %0.0f vs stated %0.0f - a %.0f%% gap, so these four numbers do not "
                   "describe one food" % (computed, cal, drift * 100)}


def _alcohol_reconciles(macros, computed, cal):
    """The ethanol term. Returns a verdict dict when the row is alcohol-bearing, else None so the
    caller falls through to the ordinary refusal.

    A VERDICT, NOT A PASS. Three separate things have to hold, and any one of them failing REFUSES
    the row with a reason that names the number - because "we could not check it" and "we checked it
    and it is wrong" are different sentences and a person rules on them differently.
    """
    cls = alcohol_class(macros.get("item"))
    if cls is None:
        return None
    band = dict(ALCOHOL_BANDS).get(cls)
    residual = float(cal) - float(computed)
    # ETHANOL ONLY ADDS CALORIES. An Atwater figure ABOVE the stated energy cannot be explained by an
    # energy carrier the sum left out, so this direction is a real disagreement in an alcoholic food
    # exactly as it is in any other, and it is refused with its own sentence rather than the generic
    # one - the generic one would send a person looking for the wrong error.
    if residual <= 0:
        return {"ok": False, "computed": round(computed, 1), "drift": None,
                "why": "Atwater %0.0f OVERSHOOTS the stated %0.0f on a %s row. Alcohol can only ADD "
                       "calories, so ethanol cannot explain this gap and the four numbers still do "
                       "not describe one food" % (computed, cal, cls)}
    grams = macros.get("serving_grams")
    if not isinstance(grams, (int, float)) or grams <= 0:
        return {"ok": False, "computed": round(computed, 1), "drift": None,
                "why": "this %s row leaves %0.0f kcal unaccounted, which is the shape of alcohol, but "
                       "it carries no usable serving_grams so the implied ethanol cannot be put on a "
                       "per-100 g basis and nothing can rule on it" % (cls, residual)}
    per100 = (residual / KCAL_PER_G_ALCOHOL) * (100.0 / float(grams))
    lo, hi = band
    if lo <= per100 <= hi:
        return {"ok": True, "computed": round(computed, 1), "drift": None,
                "alcohol_class": cls, "alcohol_g_per_100g": round(per100, 1),
                "why": "",
                "note": "the %0.0f kcal 4/4/9 leaves unaccounted implies %.1f g ethanol per 100 g, "
                        "which is inside the %s band %.1f-%.1f - the row reconciles once alcohol is "
                        "credited at %g kcal/g"
                        % (residual, per100, cls, lo, hi, KCAL_PER_G_ALCOHOL)}
    return {"ok": False, "computed": round(computed, 1), "drift": None,
            "alcohol_class": cls, "alcohol_g_per_100g": round(per100, 1),
            "why": "this %s row leaves %0.0f kcal unaccounted, which would be %.1f g ethanol per "
                   "100 g - OUTSIDE the %.1f-%.1f g band a %s actually carries, so alcohol does not "
                   "explain the gap and these four numbers do not describe one food"
                   % (cls, residual, per100, lo, hi, cls)}


CACHE_FILE = os.path.join(MP, "db", "fdc-cache.json")


def _cache_key(term):
    return " ".join(str(term or "").lower().split())


def cache_read(path=None):
    try:
        with open(path or CACHE_FILE, "r", encoding="utf-8-sig") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {"terms": {}}
    except Exception:                                             # noqa: BLE001
        return {"terms": {}}


def cache_write(cache, path=None):
    with open(path or CACHE_FILE, "w", encoding="utf-8") as f:
        json.dump(cache, f, ensure_ascii=False, indent=1)


def cache_get(term, path=None, cache=None):
    """Candidate FDC rows for a term, or None when the cache has never looked.

    KEYED BY THE RECIPE'S OWN TERM, not by a canonical food name, and that is the point. The mapper's
    expensive lookups are exactly the ones it cannot resolve - it is holding "kosher salt", not "Salt"
    - so a cache keyed by canon would miss every call worth serving.

    A MISS AND AN EMPTY RESULT ARE DIFFERENT ANSWERS. None means nobody has asked FDC about this term;
    a stored entry with an empty candidate list means FDC was asked and had nothing. Collapsing the two
    would make the pre-pass re-ask forever for foods FDC does not carry.
    """
    c = cache if cache is not None else cache_read(path)
    return (c.get("terms") or {}).get(_cache_key(term))


def cache_fill(terms, path=None, page_size=4, opener=None, key=None, pause=0.0, log=None):
    """Ask FDC about terms the cache has not seen, and store the CANDIDATES it returns.

    STORES CANDIDATES, NEVER A CHOICE. Which row is the food is an identity call and stays frontier -
    the live probe made the case: FDC's top hit for "chicken drumstick" is "Chicken, skin (drumsticks
    and thighs)" at 440 cal, which is skin. This fills a shelf; the mapper still picks off it.

    A LOOKUP THAT COULD NOT RUN IS NOT STORED. A transport failure or a missing key leaves the term
    absent so the next run retries it, rather than freezing "FDC has nothing" into the cache.

    FOUR ROWS, NOT THREE (M1, 2026-08-25). The shelf renders four candidates because FDC's curated
    tiers rarely return more than a handful and the fourth row is often the right form. It costs NO
    extra request - one search returns N rows - so the rate-limit reasoning that set this to 3 is
    untouched. Terms already cached keep their 3: cache_fill never re-asks a term it has seen.
    """
    import time                                                   # noqa: PLC0415
    c = cache_read(path)
    c.setdefault("terms", {})
    added = skipped = failed = 0
    for t in terms:
        k = _cache_key(t)
        if not k or k in c["terms"]:
            skipped += 1
            continue
        r = search(t, page_size=page_size, opener=opener, key=key)
        if not r.get("ok"):
            failed += 1
            if log:
                log("  %-34s could not run: %s" % (t[:34], r.get("why", "")[:60]))
            continue
        c["terms"][k] = {"asked": True, "candidates": r["candidates"]}
        added += 1
        if log and added <= 12:
            top = r["candidates"][0]["description"] if r["candidates"] else "(FDC has nothing)"
            log("  %-34s %s" % (t[:34], top[:52]))
        if pause:
            time.sleep(pause)
    cache_write(c, path)
    return {"added": added, "skipped": skipped, "failed": failed, "size": len(c["terms"])}


def selftest():
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    # A stubbed responder, shaped from a REAL FDC reply for "parsley, fresh" (fdcId 170416) - the very
    # food whose missing density parked a recipe today.
    real = json.dumps({"foods": [{
        "fdcId": 170416, "description": "Parsley, fresh", "dataType": "SR Legacy",
        "foodNutrients": [
            {"nutrientName": "Energy", "unitName": "KJ", "value": 151},
            {"nutrientName": "Energy", "unitName": "KCAL", "value": 36.0},
            {"nutrientName": "Protein", "unitName": "G", "value": 2.97},
            {"nutrientName": "Carbohydrate, by difference", "unitName": "G", "value": 6.33},
            {"nutrientName": "Total lipid (fat)", "unitName": "G", "value": 0.79},
            {"nutrientName": "Fiber, total dietary", "unitName": "G", "value": 3.3}],
        "foodPortions": [{"portionDescription": "1 tbsp", "gramWeight": 3.8},
                         {"portionDescription": "1 cup chopped", "gramWeight": 60.0}]}]})
    r = search("parsley, fresh", opener=lambda _u: real, key="test")
    T("a search returns candidate rows with their macros", r["ok"] and len(r["candidates"]) == 1,
      json.dumps(r)[:120])
    # MUST FIRE: FDC puts Branded first for a bare term and Branded rows are often all zeros.
    mixed = json.dumps({"foods": [
        {"fdcId": 1, "description": "PARSLEY", "dataType": "Branded",
         "foodNutrients": [{"nutrientName": "Energy", "unitName": "KCAL", "value": 0.0},
                           {"nutrientName": "Protein", "unitName": "G", "value": 0.0}]},
        {"fdcId": 2, "description": "Parsley, fresh", "dataType": "SR Legacy",
         "foodNutrients": [{"nutrientName": "Energy", "unitName": "KCAL", "value": 36.0},
                           {"nutrientName": "Protein", "unitName": "G", "value": 2.97}]}]})
    rm = search("parsley", data_types=DEFAULT_TYPES, opener=lambda _u: mixed, key="test")
    T("MUST FIRE  a curated SR Legacy row outranks a Branded one - a shelf of branded zeros is worse "
      "than an empty shelf",
      rm["candidates"][0]["data_type"] == "SR Legacy",
      json.dumps([(c["data_type"], c["macros"].get("calories")) for c in rm["candidates"]]))
    T("CLEAN TWIN nothing is DROPPED for being zero - salt and water are honestly 0/0/0",
      len(rm["candidates"]) == 2, json.dumps(len(rm["candidates"])))
    c = r["candidates"][0] if r["candidates"] else {}
    # MUST FIRE: FDC returns Energy TWICE, in KCAL and KJ. Taking whichever came first stores 151.
    T("MUST FIRE  Energy in KJ is ignored - FDC states both and 151 is not 36",
      c.get("macros", {}).get("calories") == 36.0, json.dumps(c.get("macros")))
    T("the other three macros come through", c.get("macros", {}).get("protein_g") == 2.97
      and c.get("macros", {}).get("carbs_g") == 6.33, json.dumps(c.get("macros")))
    # MUST FIRE: the household measures the food DB needs, when FDC states them.
    T("MUST FIRE  stated household portions are carried, because the food DB needs a measure AND grams",
      any(p["measure"] == "1 tbsp" and p["grams"] == 3.8 for p in c.get("portions", [])),
      json.dumps(c.get("portions")))
    # MUST FIRE: the two-stage query. Ranking cannot promote a row FDC never returned.
    calls = []
    branded_only = json.dumps({"foods": [{"fdcId": 9, "description": "PARSLEY", "dataType": "Branded",
        "foodNutrients": [{"nutrientName": "Energy", "unitName": "KCAL", "value": 0.0}]}]})
    def two_stage(url):
        calls.append(url)
        return json.dumps({"foods": []}) if "SR+Legacy" in url or "SR%20Legacy" in url else branded_only
    r2 = search("parsley", opener=two_stage, key="test")
    T("MUST FIRE  curated tiers are asked FIRST, and Branded only when they come back empty",
      len(calls) == 2 and r2["candidates"] and r2["candidates"][0]["data_type"] == "Branded",
      "calls=%d result=%s" % (len(calls), json.dumps([c["data_type"] for c in r2["candidates"]])))
    calls3 = []
    def curated_hit(url):
        calls3.append(url)
        return json.dumps({"foods": [{"fdcId": 2, "description": "Parsley, fresh",
            "dataType": "SR Legacy",
            "foodNutrients": [{"nutrientName": "Energy", "unitName": "KCAL", "value": 36.0}]}]})
    r3 = search("parsley", opener=curated_hit, key="test")
    T("CLEAN TWIN ...and when a curated row EXISTS, Branded is never asked for at all",
      len(calls3) == 1 and r3["candidates"][0]["macros"]["calories"] == 36.0,
      "calls=%d" % len(calls3))

    # MUST FIRE: could-not-look is never a clean bill.
    def boom(_u):
        raise RuntimeError("connection reset")
    rf = search("x", opener=boom, key="test")
    T("MUST FIRE  a transport failure reports CANNOT RUN, never 'no data for this food'",
      not rf["ok"] and "failed" in rf["why"] and rf["candidates"] == [], json.dumps(rf)[:120])
    # MUST FIRE: no key is a refusal that says where to put one, never a silent DEMO_KEY.
    nk = search("x", opener=lambda _u: real, key=None) if not api_key() else {"ok": False, "why": "key present"}
    T("no key yields a refusal naming where to put one (skipped if a key is configured)",
      (not nk["ok"]) and ("api.data.gov" in nk["why"] or nk["why"] == "key present"), nk["why"][:80])
    # ---- Atwater, the estate's own confirmation move --------------------------------------------
    a = atwater_check({"calories": 36.0, "protein_g": 2.97, "carbs_g": 6.33, "fat_g": 0.79,
                       "fiber_g": 3.3})
    T("MUST FIRE  Atwater confirms a coherent row once FIBRE is credited at 2 kcal/g, not 4",
      a["ok"], json.dumps(a))
    # THE FIBRE CORRECTION, ASSERTED AS WHAT IT ACTUALLY BUYS. The first version of this fixture
    # claimed the parsley row FAILS without fibre - true of the original ratio-only check, and no
    # longer true once the absolute floor landed, because 44.3 against 36 is 8 kcal and the floor
    # forgives that. Rather than invent a case that keeps the old claim alive, this asserts the true
    # one: crediting fibre at 2 kcal/g moves the computed figure MEASURABLY closer to what FDC states.
    # For parsley, 44.3 without it against 37.7 with it, on a stated 36.
    with_fib = atwater_check({"calories": 36.0, "protein_g": 2.97, "carbs_g": 6.33, "fat_g": 0.79,
                              "fiber_g": 3.3})["computed"]
    without = atwater_check({"calories": 36.0, "protein_g": 2.97, "carbs_g": 6.33,
                             "fat_g": 0.79})["computed"]
    T("MUST FIRE  crediting fibre at 2 kcal/g lands CLOSER to the stated calories than 4/4/9 does",
      abs(with_fib - 36.0) < abs(without - 36.0),
      "with fibre %s, without %s, stated 36" % (with_fib, without))
    b = atwater_check({"calories": 36.0, "protein_g": 30.0, "carbs_g": 6.33, "fat_g": 0.79})
    T("MUST FIRE  ...and refuses one where the four numbers cannot describe one food",
      not b["ok"] and "do not" in b["why"], json.dumps(b))
    # MUST FIRE: the two live cases that broke the first version of this check.
    z = atwater_check({"calories": 0.0, "protein_g": 0.0, "carbs_g": 0.0, "fat_g": 0.0})
    T("MUST FIRE  a genuine ZERO-calorie food passes - monk fruit sweetener is not a broken row",
      z["ok"], json.dumps(z))
    tiny = atwater_check({"calories": 5.0, "protein_g": 0.0, "carbs_g": 3.91, "fat_g": 0.0,
                          "fiber_g": 2.2})
    T("MUST FIRE  ...and a 5-kcal food is not judged by RATIO - cactus paddles read 140% drift on a "
      "7-kcal difference",
      tiny["ok"], json.dumps(tiny))
    big = atwater_check({"calories": 20.0, "protein_g": 40.0, "carbs_g": 0.0, "fat_g": 0.0})
    T("MUST FIRE  ...but a real mismatch still fails, absolute floor or not (160 computed vs 20)",
      not big["ok"], json.dumps(big))
    c2 = atwater_check({"calories": 36.0, "protein_g": 2.97, "carbs_g": None, "fat_g": 0.79})
    T("MUST FIRE  a row missing a macro is not silently Atwater-passed",
      not c2["ok"], json.dumps(c2))

    # ---- ETHANOL, THE FOURTH TERM (2026-08-26) ---------------------------------------------------
    # WHAT THIS COST BEFORE IT EXISTED: on run hunt-2026-08-26-ten the Dry White Wine and Dry Red
    # Wine rows were refused at 87% gaps and the recipes carrying them went STUCK at the write lane.
    # Both rows were exactly right. Every fixture below uses REAL numbers off the live food DB or
    # USDA SR, so a band that drifts away from the foods it describes fails here.
    wine = atwater_check({"item": "Dry Red Wine", "serving_grams": 100, "calories": 85,
                          "protein_g": 0.1, "carbs_g": 2.6, "fat_g": 0})
    T("MUST FIRE  a wine row RECONCILES once ethanol is credited at 7 kcal/g - 4/4/9 computes 11 "
      "against a stated 85 and the row is correct",
      wine["ok"] and 9.0 <= wine.get("alcohol_g_per_100g", 0) <= 12.0, json.dumps(wine))
    for name, grams, cal, pro, carb, fat, lo, hi in (
            ("Dry White Wine",  100, 82,  0.1,  2.6,   0,    9.0, 11.5),   # live DB row
            ("Marsala Wine",    100, 152, 0.2,  11.7,  0,    13.0, 17.0),  # live DB row, fortified
            ("Bourbon",         100, 231, 0,    0,     0,    30.0, 36.0),  # USDA 80-proof spirits
            ("Regular Beer",    100, 43,  0.46, 3.55,  0,    3.0, 5.0),    # USDA beer, regular
            ("Vanilla Extract", 100, 288, 0.06, 12.65, 0.06, 30.0, 37.0)): # USDA vanilla extract
        r = atwater_check({"item": name, "serving_grams": grams, "calories": cal,
                           "protein_g": pro, "carbs_g": carb, "fat_g": fat})
        T("MUST FIRE  %s reconciles on the ethanol term and lands in its own class band" % name,
          r["ok"] and lo <= r.get("alcohol_g_per_100g", 0) <= hi, json.dumps(r))
    # THE BAND IS THE GATE, AND THIS IS THE FIXTURE THAT PROVES IT IS STILL ONE. A row named "wine"
    # does not get a pass; it gets an ETHANOL BUDGET, and a fabrication overruns it. 600 kcal of wine
    # implies 84 g of ethanol in 100 g of liquid, which is stronger than any drinkable thing.
    fake = atwater_check({"item": "Dry Red Wine", "serving_grams": 100, "calories": 600,
                          "protein_g": 0.1, "carbs_g": 2.6, "fat_g": 0})
    T("MUST FIRE  a FABRICATED wine row is still REFUSED - naming a food 'wine' buys an ethanol "
      "budget, never an exemption",
      not fake["ok"] and "OUTSIDE" in fake["why"], json.dumps(fake))
    over = atwater_check({"item": "Chardonnay", "serving_grams": 100, "calories": 5,
                          "protein_g": 0.1, "carbs_g": 20.0, "fat_g": 0})
    T("MUST FIRE  an Atwater figure ABOVE the stated calories is refused on an alcoholic row too - "
      "ethanol only ADDS calories, so it cannot explain that direction",
      not over["ok"] and "OVERSHOOT" in over["why"], json.dumps(over))
    nog = atwater_check({"item": "Dry Red Wine", "calories": 85, "protein_g": 0.1,
                         "carbs_g": 2.6, "fat_g": 0})
    T("MUST FIRE  an alcoholic row with no serving_grams is REFUSED, not waved through - the implied "
      "ethanol cannot be put on a per-100 g basis and nothing can rule on it",
      not nog["ok"] and "serving_grams" in nog["why"], json.dumps(nog))
    # MUST FIRE: the live DB carries Red Wine Vinegar, White Wine Vinegar and Rice Vinegar. A matcher
    # that reads the word "wine" would hand all three an ethanol budget they have no claim to.
    T("MUST FIRE  vinegar is NOT alcohol-bearing however much its name says wine",
      alcohol_class("Red Wine Vinegar") is None and alcohol_class("White Wine Vinegar") is None,
      "red=%s white=%s" % (alcohol_class("Red Wine Vinegar"), alcohol_class("White Wine Vinegar")))
    T("MUST FIRE  root beer and a non-alcoholic wine get no ethanol budget either",
      alcohol_class("Root Beer") is None and alcohol_class("Non-Alcoholic Wine") is None,
      "rootbeer=%s na=%s" % (alcohol_class("Root Beer"), alcohol_class("Non-Alcoholic Wine")))
    # CLEAN TWIN: the whole ethanol road is only reachable AFTER the ordinary check has failed, so
    # nothing that passes today can change answer because a name matched.
    T("CLEAN TWIN a NON-alcoholic row is untouched by any of this - it never reaches the alcohol road",
      atwater_check({"item": "Chicken Breast", "serving_grams": 100, "calories": 165,
                     "protein_g": 31.0, "carbs_g": 0, "fat_g": 3.6})["ok"], "chicken breast")
    T("MUST FIRE  ...and a non-alcoholic row whose numbers genuinely disagree is refused exactly as "
      "before, with no ethanol sentence in its reason",
      (lambda r: not r["ok"] and "ethanol" not in r["why"])(
          atwater_check({"item": "Ground Cinnamon", "serving_grams": 100, "calories": 20,
                         "protein_g": 40.0, "carbs_g": 0, "fat_g": 0})),
      json.dumps(atwater_check({"item": "Ground Cinnamon", "serving_grams": 100, "calories": 20,
                                "protein_g": 40.0, "carbs_g": 0, "fat_g": 0})))
    # ---- THE CACHE -------------------------------------------------------------------------------
    import tempfile                                               # noqa: PLC0415
    tmp = os.path.join(tempfile.mkdtemp(prefix="fdccache-"), "c.json")
    st = cache_fill(["parsley, fresh"], path=tmp, opener=lambda _u: real, key="test")
    T("a fill stores what FDC returned", st["added"] == 1 and st["size"] == 1, json.dumps(st))
    T("MUST FIRE  the cache is keyed by the RECIPE's term, so a later lookup by that term hits",
      cache_get("Parsley, Fresh", path=tmp) is not None, "keyed lookup missed")
    st2 = cache_fill(["parsley, fresh"], path=tmp, opener=lambda _u: real, key="test")
    T("MUST FIRE  a term already asked is not re-asked - that is what the cache is for",
      st2["added"] == 0 and st2["skipped"] == 1, json.dumps(st2))
    # MUST FIRE: a miss and an empty answer are different, or the pre-pass re-asks forever.
    empty = json.dumps({"foods": []})
    cache_fill(["nothing-food"], path=tmp, opener=lambda _u: empty, key="test")
    got = cache_get("nothing-food", path=tmp)
    T("MUST FIRE  'FDC was asked and had nothing' is STORED, and is not the same as never having asked",
      got is not None and got["candidates"] == [] and cache_get("never-asked-food", path=tmp) is None,
      json.dumps(got))
    # MUST FIRE: a failed lookup must not freeze into the cache as an answer.
    def boom2(_u):
        raise RuntimeError("timeout")
    st3 = cache_fill(["flaky-food"], path=tmp, opener=boom2, key="test")
    T("MUST FIRE  a lookup that COULD NOT RUN is not stored, so the next run retries it",
      st3["failed"] == 1 and cache_get("flaky-food", path=tmp) is None, json.dumps(st3))

    print("")
    if bad:
        print("fdc_lookup SELF-TEST FAIL: %d case(s)" % len(bad))
        return 1
    print("fdc_lookup SELF-TEST PASS")
    return 0


if __name__ == "__main__":
    import sys
    if "--selftest" in sys.argv:
        raise SystemExit(selftest())
    if "--key-status" in sys.argv:
        print("FDC key configured: %s" % ("yes" if api_key() else "NO - " + _blocked()["why"]))
        raise SystemExit(0)
    if "--fill-cache" in sys.argv:
        import time                                               # noqa: PLC0415
        n = 150
        for i, a in enumerate(sys.argv):
            if a == "--fill-cache" and i + 1 < len(sys.argv) and sys.argv[i + 1].isdigit():
                n = int(sys.argv[i + 1])
        src = os.environ.get("FDC_TERMS_FILE", "")
        if not src or not os.path.exists(src):
            print("fdc_lookup --fill-cache: CANNOT RUN - set FDC_TERMS_FILE to a JSON list of terms")
            raise SystemExit(2)
        with open(src, "r", encoding="utf-8-sig") as f:
            terms = [t for t in json.load(f) if isinstance(t, str)][:n]
        print("fdc_lookup --fill-cache: %d term(s), pausing 0.2s between calls" % len(terms))
        st = cache_fill(terms, pause=0.2, log=print)
        print("  added %(added)d, already cached %(skipped)d, could not run %(failed)d, cache holds %(size)d"
              % st)
        raise SystemExit(0)
    term = " ".join(a for a in sys.argv[1:] if not a.startswith("--")) or "parsley, fresh"
    res = search(term)
    print(json.dumps(res, indent=1)[:2400])
