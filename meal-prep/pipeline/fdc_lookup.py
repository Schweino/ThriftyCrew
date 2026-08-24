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


def search(term, page_size=5, data_types=DEFAULT_TYPES, opener=None, key=None):
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
    return {"ok": drift <= tolerance, "computed": round(computed, 1), "drift": round(drift, 3),
            "why": "" if drift <= tolerance else
                   "Atwater %0.0f vs stated %0.0f - a %.0f%% gap, so these four numbers do not "
                   "describe one food" % (computed, cal, drift * 100)}


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
    term = " ".join(a for a in sys.argv[1:] if not a.startswith("--")) or "parsley, fresh"
    res = search(term)
    print(json.dumps(res, indent=1)[:2400])
