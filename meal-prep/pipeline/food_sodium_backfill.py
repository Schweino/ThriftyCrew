"""food_sodium_backfill.py - store sodium per serving on the food-DB rows that can PROVE it.

Backlog I137, option A, ruled by Brad 2026-09-19: "stored, not shown". An optional `sodium_mg` goes on
`food-macros-db.json`, on EXACTLY the basis the row's other numbers use (per serving, where
`serving_grams` is that serving's weight), with `sodium_source` saying where it came from. NOTHING here
renders it, and nothing may, until every ingredient of a recipe has a value - and even then showing it
is a separate decision. `--coverage` answers how far that is.

WHERE A VALUE MAY COME FROM, in order, and nowhere else:

  1. a LABEL CAPTURE (`db/food-label-captures.json`) whose status is LABEL or PROXY and whose panel
     states sodium. A capture WINS over FDC: it is the product the board prices, read off its panel.
     CONFLICT captures are NOT used - "the panel disagrees with the stored row and NOTHING was
     written" is the capture file's own definition, so the panel is not this row's food (the soy
     sauce CONFLICT is a regular 900 mg bottle against a row that is USDA LOW-SODIUM soy sauce).
     sodium_source = `label-capture:db/food-label-captures.json#<item>`.
  2. the FDC id the row's OWN text cites (the first id in `source`, else `verify_source`, else the
     notes), fetched live, and only when that record REPRODUCES THE ROW'S FOUR MACROS inside
     `food_source_backfill`'s stated tolerance, both put on per 100 g. That check is the whole point:
     sodium per 100 g is only this row's sodium when the record is this row's food on this row's
     basis. A cited record that disagrees - a drained row citing a solids-and-liquids record, a
     bone-in as-purchased row citing an edible-portion record, an NDB number written as an FDC id -
     is reported and NOT written. sodium_source = `fdc:<id>`.

Anything else gets NO field at all. Never a guess and never a 0 for unknown: an absent `sodium_mg`
means "nobody knows", and a 0 means the food declares none (oil, water), with a source saying so.

THE I137 FINDINGS THIS OBEYS. NDB numbers are not FDC ids (`FDC/SR 01056` is excluded by the regex,
and a 5-digit NDB number written as `USDA FDC 11090` fails the macro check rather than being
trusted). The `full` format drops nutrient identities on some Branded records, so this asks for
`abridged` and reads nutrients by NUMBER (307 sodium, 208 energy kcal, 203 protein, 205 carbohydrate,
204 fat; Foundation records without 208 fall back to the Atwater energies 958, then 957).

THE KEY is read by `fdc_lookup.api_key()` (FDC_API_KEY, the file FDC_KEY_FILE names, or
meal-prep/db/fdc-api-key.txt). It is never printed, logged or written anywhere.

Usage:
  food_sodium_backfill.py --fetch --cache <path>        fetch every cited FDC id (abridged) to a cache
  food_sodium_backfill.py --plan --cache <path> [--out <jsonl>]   one row per food-DB row, tallies
  food_sodium_backfill.py --write --cache <path>        apply the plan to food-macros-db.json
  food_sodium_backfill.py --coverage                    how many recipes have sodium on EVERY ingredient
  food_sodium_backfill.py --selftest
"""
# The self-test is pure over in-file rows and temp specs; it imports three sibling modules the key cannot walk.
# gate-inputs: meal-prep\pipeline\food_sodium_backfill.py, meal-prep\pipeline\fdc_lookup.py, meal-prep\pipeline\food_provenance.py, meal-prep\pipeline\food_source_backfill.py
from __future__ import annotations

import collections
import glob
import json
import math
import os
import re
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import fdc_lookup                                                  # noqa: E402
import food_provenance as fp                                       # noqa: E402
import food_source_backfill as fsb                                 # noqa: E402

MP = fp.MP
FOODS_URL = "https://api.nal.usda.gov/fdc/v1/foods"
CAPTURES_REL = "db/food-label-captures.json"

# The I137 rung-1 regex, verbatim: `FDC/SR 01056` is an NDB number and is not read as an FDC id.
FDC_ID_RX = re.compile(r"(?:FDC|fdc)(?!/SR)[^0-9\n]{0,40}?(\d{5,7})")
# The row's own citation first. `source` is the field that says what the row's numbers ARE; the notes
# are read only when it names no id, and they often name a REJECTED record too, so first-hit wins.
TEXT_FIELDS = ("source", "verify_source", "notes", "note", "needs_verify_note")
LABEL_USABLE = ("LABEL", "PROXY")

NUM_SODIUM = "307"
NUM_KCAL = ("208", "958", "957")
NUM_MACRO = {"203": "protein_g", "205": "carbs_g", "204": "fat_g"}


def cited_fdc_id(row):
    """(fdc id as int, field it came from), or (None, None)."""
    for f in TEXT_FIELDS:
        m = FDC_ID_RX.search(str(row.get(f) or ""))
        if m:
            return int(m.group(1)), f
    return None, None


def _num(n):
    for k in ("number", "nutrientNumber"):
        v = n.get(k)
        if v is None and isinstance(n.get("nutrient"), dict):
            v = n["nutrient"].get(k)
        if v is not None:
            return str(v).strip()
    return ""


def _amount(n):
    for k in ("amount", "value"):
        v = n.get(k)
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            return float(v)
    return None


def _unit(n):
    u = n.get("unitName")
    if u is None and isinstance(n.get("nutrient"), dict):
        u = n["nutrient"].get("unitName")
    return str(u or "").upper()


def fdc_per_100g(food):
    """{sodium_mg, calories, protein_g, carbs_g, fat_g} per 100 g from an FDC record, by nutrient
    NUMBER. A nutrient the record does not state is absent, never 0."""
    by = {}
    for n in (food.get("foodNutrients") or []):
        num, amt = _num(n), _amount(n)
        if num and amt is not None and num not in by:
            by[num] = (amt, _unit(n))
    out = {}
    if NUM_SODIUM in by and by[NUM_SODIUM][1] in ("MG", ""):
        out["sodium_mg"] = by[NUM_SODIUM][0]
    for k in NUM_KCAL:
        if k in by and by[k][1] in ("KCAL", ""):
            out["calories"] = by[k][0]
            break
    for num, field in NUM_MACRO.items():
        if num in by:
            out[field] = by[num][0]
    return out


# LABEL ROUNDING AT THE ROW'S OWN SERVING. food_source_backfill's tolerance compares per 100 g, which is
# right for a 100 g row and wrong for a 2.6 g teaspoon: a panel declares grams to the nearest whole
# gram and under 0.5 g as 0, and calories to the nearest 5, so a spice row reading "0 g protein per
# tsp" is 0 per 100 g against FDC's 4.0 and reads as a different food when it is the same one. So a
# field also agrees when the two differ by no more than the panel's own rounding AT THE ROW'S SERVING:
# 0.5 g for a macro, 5 kcal for calories. ADDED AFTER THE FIRST RUN, and stated as such: that run over
# the 441 rows at the per-100-g tolerance alone skipped five rows, four of them spices at 2.1 to 2.8 g
# (Ground Cinnamon, Ground Cloves, Ground Ginger, Poppy Seeds), whose calories agreed per 100 g. The
# fifth, Beef Back Ribs (99 kcal per 100 g as purchased bone-in against 324 edible), is 225 kcal apart
# at its 100 g serving and stays refused, which is the case this check exists for. One variant tried.
ROUND_G, ROUND_KCAL = 0.5, 5.0


def basis_disagrees(stored, cand, serving_g):
    off, text = fsb.compare(stored, cand)
    f = serving_g / 100.0
    kept = []
    for k in off:
        slack = ROUND_KCAL if k == "calories" else ROUND_G
        if abs(stored[k] - cand[k]) * f > slack:
            kept.append(k)
    return kept, text


def _clean(v):
    v = round(float(v), 1)
    return int(v) if v == int(v) else v


def plan_row(idx, row, captures_by_item, foods, looked):
    """One decision for one food-DB row: {idx, item, action: label|fdc|skip, sodium_mg?, sodium_source?,
    why}. `foods` maps fdc id -> record; `looked` is the set of ids a fetch actually asked about, so an
    id nobody asked about is a could-not-look, never a no-sodium."""
    item = str(row.get("item") or "")
    base = {"idx": idx, "item": item}
    sg = row.get("serving_grams")
    if not isinstance(sg, (int, float)) or isinstance(sg, bool) or sg <= 0:
        return dict(base, action="skip", why="row has no positive serving_grams, so no per-serving basis")
    cap = captures_by_item.get(item)
    if cap is not None:
        lab = cap.get("label") or {}
        na, cg = lab.get("sodium_mg"), lab.get("serving_g")
        usable = (cap.get("status") in LABEL_USABLE and isinstance(na, (int, float))
                  and not isinstance(na, bool) and na >= 0
                  and isinstance(cg, (int, float)) and cg > 0)
        if usable:
            return dict(base, action="label", sodium_mg=_clean(float(na) * float(sg) / float(cg)),
                        sodium_source="label-capture:%s#%s" % (CAPTURES_REL, item),
                        why="%s capture states %s mg per %s g; row serving is %s g"
                            % (cap.get("status"), na, cg, sg))
        cap_why = ("capture is %s" % cap.get("status")) if cap.get("status") not in LABEL_USABLE \
            else "capture panel states no sodium"
    else:
        cap_why = "no label capture"
    fid, field = cited_fdc_id(row)
    if fid is None:
        return dict(base, action="skip", why="%s and the row cites no FDC id" % cap_why)
    base["fdc_id"], base["fdc_field"] = fid, field
    if fid not in looked:
        return dict(base, action="skip", why="FDC %d was not looked up (could not look)" % fid)
    food = foods.get(fid)
    if food is None:
        return dict(base, action="skip", why="FDC %d did not answer in the abridged format" % fid)
    base["data_type"] = food.get("dataType")
    n = fdc_per_100g(food)
    if "sodium_mg" not in n:
        return dict(base, action="skip", why="FDC %d states no sodium" % fid)
    stored = fsb.per_100g(row)
    if stored is None or any(k not in n for k in ("calories", "protein_g", "carbs_g", "fat_g")):
        return dict(base, action="skip",
                    why="FDC %d or the row lacks one of the four macros, so the basis cannot be proven" % fid)
    off, text = basis_disagrees(stored, n, float(sg))
    if off:
        return dict(base, action="skip", off=off,
                    why="FDC %d is not this row's food on this row's basis (%s disagree): %s"
                        % (fid, ",".join(off), text))
    return dict(base, action="fdc", sodium_mg=_clean(n["sodium_mg"] * float(sg) / 100.0),
                sodium_source="fdc:%d" % fid,
                why="FDC %d reproduces the row's macros; %s" % (fid, text))


def plan(db, captures, foods, looked):
    by_item = {}
    for c in (captures or []):
        if isinstance(c, dict) and c.get("item"):
            by_item[str(c["item"])] = c
    return [plan_row(i, r, by_item, foods, looked)
            for i, r in enumerate(db.get("items", [])) if isinstance(r, dict) and r.get("item")]


def apply_plan(db, rows):
    """Writes sodium_mg and sodium_source, and NOTHING else. A row that already carries a different
    value is REFUSED and reported, never overwritten. Returns (written, unchanged, refused)."""
    items = db["items"]
    written, same, refused = 0, 0, []
    for p in rows:
        if p["action"] not in ("label", "fdc"):
            continue
        r = items[p["idx"]]
        if r.get("item") != p["item"]:
            refused.append("%s: row index moved" % p["item"])
            continue
        if "sodium_mg" in r:
            if r.get("sodium_mg") == p["sodium_mg"] and r.get("sodium_source") == p["sodium_source"]:
                same += 1
            else:
                refused.append("%s: already holds %r from %r" % (p["item"], r.get("sodium_mg"),
                                                                 r.get("sodium_source")))
            continue
        r["sodium_mg"] = p["sodium_mg"]
        r["sodium_source"] = p["sodium_source"]
        written += 1
    return written, same, refused


def fetch(ids, key, opener=None, batch=20, pause=1.5, log=print):
    """{id: record} for every id FDC answers, plus the set of ids actually asked about. A batch that
    errors is NOT added to `looked`, so its ids read as could-not-look rather than as no-sodium."""
    foods, looked = {}, set()
    ids = sorted(set(int(i) for i in ids))
    for s in range(0, len(ids), batch):
        chunk = ids[s:s + batch]
        body = json.dumps({"fdcIds": chunk, "format": "abridged"}).encode("utf-8")
        req = urllib.request.Request(FOODS_URL + "?api_key=" + key, data=body,
                                     headers={"Content-Type": "application/json"})
        try:
            if opener is not None:
                data = opener(req)
            else:
                with urllib.request.urlopen(req, timeout=60) as resp:
                    data = json.loads(resp.read().decode("utf-8"))
        except Exception as e:                                     # noqa: BLE001
            # The exception text can carry the request URL, and the URL carries the key: say the class only.
            log("  batch %d-%d could not be read (%s); its ids stay could-not-look"
                % (s, s + len(chunk) - 1, type(e).__name__))
            continue
        looked.update(chunk)
        for rec in (data or []):
            fid = rec.get("fdcId")
            if isinstance(fid, int):
                foods[fid] = rec
        if pause and s + batch < len(ids):
            time.sleep(pause)
    return foods, looked


def coverage(db, spec_dir=None):
    """Of the recipe specs, how many have a sodium value on EVERY ingredient line. An ingredient with
    no food-DB row at all counts as uncovered: nobody can say its sodium."""
    by = {str(r["item"]): r for r in db.get("items", []) if isinstance(r, dict) and r.get("item")}
    total, full = 0, 0
    blockers = collections.Counter()
    for path in sorted(glob.glob(os.path.join(spec_dir or fp.SPEC_DIR, "*.json"))):
        try:
            with open(path, "r", encoding="utf-8-sig") as f:
                spec = json.load(f)
        except Exception:                                          # noqa: BLE001
            continue
        lines = spec.get("ingredients_grams") or []
        names = sorted(set(str(x.get("item") or "") for x in lines if x.get("item")))
        if not names:
            continue
        total += 1
        missing = [n for n in names if "sodium_mg" not in (by.get(n) or {})]
        if not missing:
            full += 1
        for n in missing:
            blockers[n] += 1
    return {"specs": total, "fully_covered": full, "blockers": blockers}


# ---- selftest ---------------------------------------------------------------------------------

def _row(name, sg=100.0, cal=100.0, p=5.0, c=10.0, f=2.0, **kw):
    r = {"item": name, "serving_grams": sg, "serving_qty": 1, "serving_unit": "serving",
         "calories": cal, "protein_g": p, "carbs_g": c, "fat_g": f}
    r.update(kw)
    return r


def _food(fid, na=400.0, cal=100.0, p=5.0, c=10.0, f=2.0, dt="SR Legacy", kcal_num="208"):
    nut = [{"number": kcal_num, "name": "Energy", "amount": cal, "unitName": "kcal"},
           {"number": "203", "name": "Protein", "amount": p, "unitName": "g"},
           {"number": "205", "name": "Carbohydrate, by difference", "amount": c, "unitName": "g"},
           {"number": "204", "name": "Total lipid (fat)", "amount": f, "unitName": "g"}]
    if na is not None:
        nut.append({"number": "307", "name": "Sodium, Na", "amount": na, "unitName": "mg"})
    return {"fdcId": fid, "dataType": dt, "foodNutrients": nut}


def selftest():
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    # The id the row's own `source` cites wins over one its notes mention (often a REJECTED record).
    r = _row("Corn", source="USDA FDC 169214 (SR Legacy) drained", notes="matches FDC 169360 undrained")
    T("MUST FIRE  the id in `source` wins over an id the notes mention", cited_fdc_id(r) == (169214, "source"),
      cited_fdc_id(r))
    T("MUST FIRE  an NDB number written FDC/SR is not read as an FDC id",
      cited_fdc_id(_row("Oats", source="FDC/SR 01056")) == (None, None), cited_fdc_id(_row("Oats", source="FDC/SR 01056")))

    # Sodium is read by NUMBER, and per serving on the row's own gram basis.
    foods = {111111: _food(111111, na=400.0)}
    p = plan_row(0, _row("Thing", sg=50.0, cal=50.0, p=2.5, c=5.0, f=1.0, source="fdc:111111"), {}, foods, {111111})
    T("MUST FIRE  an FDC value is scaled per 100 g -> the row's serving grams (400 mg/100 g x 50 g = 200)",
      p["action"] == "fdc" and p["sodium_mg"] == 200 and p["sodium_source"] == "fdc:111111", json.dumps(p)[:200])
    # A record that disagrees with the row's macros is not this row's food on this row's basis.
    p = plan_row(0, _row("Ribs", cal=100.0, source="fdc:111111"), {}, {111111: _food(111111, cal=221.0)}, {111111})
    T("MUST FIRE  a cited record whose calories disagree is SKIPPED, not scaled - the bone-in yield shape",
      p["action"] == "skip" and "calories" in p.get("off", []), json.dumps(p)[:200])
    p = plan_row(0, _row("Cinnamon", sg=2.6, cal=6.0, p=0.0, c=2.0, f=0.0, source="fdc:171320"), {},
                 {171320: _food(171320, na=10.0, cal=247.0, p=4.0, c=80.6, f=1.2)}, {171320})
    T("CLEAN TWIN a teaspoon row whose '0 g protein' is the panel's rounding is still the same food",
      p["action"] == "fdc" and p["sodium_mg"] == 0.3, json.dumps(p)[:200])
    p = plan_row(0, _row("Bulk", sg=100.0, cal=247.0, p=0.0, c=80.6, f=1.2, source="fdc:171320"), {},
                 {171320: _food(171320, na=10.0, cal=247.0, p=4.0, c=80.6, f=1.2)}, {171320})
    T("MUST FIRE  the same 4 g protein gap on a 100 g serving is NOT rounding and is refused",
      p["action"] == "skip" and p.get("off") == ["protein_g"], json.dumps(p)[:200])
    p = plan_row(0, _row("Nothing", source="fdc:222222"), {}, {}, set())
    T("MUST FIRE  an id nobody looked up is could-not-look, never 'no sodium'",
      p["action"] == "skip" and "could not look" in p["why"], p["why"])
    p = plan_row(0, _row("Dry", source="fdc:333333"), {}, {333333: _food(333333, na=None)}, {333333})
    T("MUST FIRE  a record stating no sodium writes nothing - never a 0 for unknown",
      p["action"] == "skip" and "sodium_mg" not in p, json.dumps(p)[:200])
    p = plan_row(0, _row("Oil", cal=884.0, p=0.0, c=0.0, f=100.0, source="fdc:444444"), {},
                 {444444: _food(444444, na=0.0, cal=884.0, p=0.0, c=0.0, f=100.0)}, {444444})
    T("CLEAN TWIN a DECLARED 0 is written as 0 with its source - zero is a value, absent is unknown",
      p["action"] == "fdc" and p["sodium_mg"] == 0, json.dumps(p)[:200])
    p = plan_row(0, _row("Kale", source="fdc:555555"), {}, {555555: _food(555555, kcal_num="958")}, {555555})
    T("CLEAN TWIN a Foundation record with only the Atwater energy (958) still proves its basis",
      p["action"] == "fdc", json.dumps(p)[:200])

    # Label captures win, CONFLICT never counts.
    caps = {"Broth": {"item": "Broth", "status": "LABEL", "label": {"sodium_mg": 830, "serving_g": 240}}}
    p = plan_row(0, _row("Broth", sg=240.0, cal=10, p=1, c=0, f=0, source="fdc:111111"), caps,
                 {111111: _food(111111, na=10.0, cal=4.2, p=0.4, c=0, f=0)}, {111111})
    T("MUST FIRE  a LABEL capture wins over the row's FDC id",
      p["action"] == "label" and p["sodium_mg"] == 830 and p["sodium_source"].startswith("label-capture:"),
      json.dumps(p)[:200])
    caps = {"Soy": {"item": "Soy", "status": "CONFLICT", "label": {"sodium_mg": 900, "serving_g": 15}}}
    p = plan_row(0, _row("Soy"), caps, {}, set())
    T("MUST FIRE  a CONFLICT capture is not this row's food and writes nothing",
      p["action"] == "skip" and "CONFLICT" in p["why"], json.dumps(p)[:200])
    caps = {"Half": {"item": "Half", "status": "PROXY", "label": {"sodium_mg": 100, "serving_g": 50}}}
    p = plan_row(0, _row("Half", sg=100.0), caps, {}, set())
    T("CLEAN TWIN a capture on a different gram serving is scaled to the row's serving (100 mg/50 g -> 200)",
      p["action"] == "label" and p["sodium_mg"] == 200, json.dumps(p)[:200])

    # apply_plan writes two fields and never overwrites a different stored value.
    db = {"items": [_row("A", source="fdc:171001"), _row("B", sodium_mg=5, sodium_source="fdc:171002")]}
    before = json.dumps(db["items"][0], sort_keys=True)
    rows = [{"idx": 0, "item": "A", "action": "fdc", "sodium_mg": 12, "sodium_source": "fdc:171001"},
            {"idx": 1, "item": "B", "action": "fdc", "sodium_mg": 9, "sodium_source": "fdc:171002"}]
    w, same, ref = apply_plan(db, rows)
    a = dict(db["items"][0])
    a.pop("sodium_mg", None)
    a.pop("sodium_source", None)
    T("MUST FIRE  a stored sodium that differs is REFUSED, not overwritten",
      w == 1 and len(ref) == 1 and db["items"][1]["sodium_mg"] == 5, "%d %s" % (w, ref))
    T("CLEAN TWIN the write touches sodium_mg and sodium_source and nothing else",
      json.dumps(a, sort_keys=True) == before and db["items"][0]["sodium_mg"] == 12, json.dumps(db["items"][0]))
    T("CLEAN TWIN everything written passes the food-DB sodium gate", fp.sodium_violations(db) == [],
      fp.sodium_violations(db))

    # Coverage: a recipe is covered only when EVERY ingredient has a value.
    import shutil                                                  # noqa: PLC0415
    import tempfile                                                # noqa: PLC0415
    tmp = tempfile.mkdtemp(prefix="sodbf-")
    try:
        for slug, items in (("one", ["A", "B"]), ("two", ["A"]), ("three", ["A", "Ghost"])):
            with open(os.path.join(tmp, slug + ".json"), "w", encoding="utf-8") as f:
                json.dump({"slug": slug, "ingredients_grams": [{"item": i, "grams": 10} for i in items]}, f)
        cdb = {"items": [_row("A", sodium_mg=1, sodium_source="fdc:171001"), _row("B")]}
        cv = coverage(cdb, spec_dir=tmp)
        T("MUST FIRE  one uncovered ingredient, or one with no food-DB row, leaves the recipe uncovered",
          cv["specs"] == 3 and cv["fully_covered"] == 1 and cv["blockers"]["Ghost"] == 1,
          json.dumps({"specs": cv["specs"], "full": cv["fully_covered"]}))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("food_sodium_backfill self-test: %d assertion(s) failed" % len(bad) if bad
          else "food_sodium_backfill self-test: all assertions passed")
    return 1 if bad else 0


def _arg(name, default=None):
    if name in sys.argv:
        i = sys.argv.index(name)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default


def _load_cache(path):
    with open(path, "r", encoding="utf-8") as f:
        doc = json.load(f)
    return {int(k): v for k, v in doc["foods"].items()}, set(int(i) for i in doc["looked"])


def main():
    if "--selftest" in sys.argv:
        return selftest()
    db = fp.load_db()
    if "--coverage" in sys.argv:
        cv = coverage(db)
        have = sum(1 for r in db["items"] if "sodium_mg" in r)
        print("food-DB rows with sodium_mg: %d of %d" % (have, len(db["items"])))
        print("recipes with sodium on EVERY ingredient: %d of %d" % (cv["fully_covered"], cv["specs"]))
        print("ingredients most often blocking a recipe (recipes blocked):")
        for n, k in cv["blockers"].most_common(int(_arg("--top", "15"))):
            print("  %4d  %s" % (k, n))
        return 0
    cache = _arg("--cache")
    if not cache:
        print("--cache <path> is required (outside the repo: it is a scratch copy of FDC's answers)")
        return 2
    if "--fetch" in sys.argv:
        key = fdc_lookup.api_key()
        if not key:
            print(fdc_lookup._blocked()["why"])
            return 2
        ids = set()
        for r in db["items"]:
            fid, _ = cited_fdc_id(r)
            if fid is not None:
                ids.add(fid)
        foods, looked = fetch(ids, key)
        with open(cache, "w", encoding="utf-8", newline="\n") as f:
            json.dump({"fetched": time.strftime("%Y-%m-%d %H:%M:%S"), "format": "abridged",
                       "looked": sorted(looked), "foods": {str(k): v for k, v in foods.items()}}, f)
        print("asked FDC about %d cited id(s): %d looked, %d answered -> %s"
              % (len(ids), len(looked), len(foods), cache))
        return 0 if looked == ids else 3
    foods, looked = _load_cache(cache)
    with open(os.path.join(MP, CAPTURES_REL), "r", encoding="utf-8-sig") as f:
        captures = json.load(f).get("captures") or []
    rows = plan(db, captures, foods, looked)
    tally = collections.Counter(r["action"] for r in rows)
    print("planned over %d food-DB row(s): %s" % (len(rows), json.dumps(dict(sorted(tally.items())))))
    out = _arg("--out")
    if out:
        with open(out, "w", encoding="utf-8", newline="\n") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n")
        print("  one row per food-DB row -> %s" % out)
    if "--write" in sys.argv:
        w, same, refused = apply_plan(db, rows)
        for x in refused:
            print("  REFUSED  " + x)
        v = fp.sodium_violations(db)
        if v or refused:
            for x in v:
                print("  X     " + x)
            print("nothing written: %d violation(s), %d refusal(s)" % (len(v), len(refused)))
            return 1
        with open(fp.DB_PATH, "w", encoding="utf-8", newline="\n") as f:
            json.dump(db, f, ensure_ascii=False, indent=1)
        print("wrote sodium on %d row(s), %d already held the same value" % (w, same))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
