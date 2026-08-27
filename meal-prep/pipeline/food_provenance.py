"""food_provenance.py - who says so, for every row in the food macro DB.

WHY THIS EXISTS (2026-08-26, rung 1 of design\\PLAN-food-db-provenance-2026-08-26.md). The DB holds
376 rows and 204 of them carry no `source`. Measured, that is an AUDITABILITY gap and not a pile of
known errors: the one unsourced row this estate hand-audited against a photographed label - Great
Value Cheese Tortellini - was EXACTLY right, and the conflict rule that refused to overwrite it was
refusing a worse reading. So nothing here treats "no source" as "wrong". The correct prior for an
unsourced row is UNKNOWN and the whole job is to make it knowable.

WHAT THE THREE CLASSES ARE FOR. Splitting the 204 by what the food actually IS is what makes the
work tractable, because frequency is inverted against difficulty: the rows used in hundreds of
recipes are onions and salt, which need no store label at all, and the rows that need a photographed
label are used once or twice each.

  A - generic whole food / commodity staple. USDA SR Legacy and Foundation are CURATED whole-food
      references; for these they are BETTER than a store label, not a fallback. Unattended, no
      browser, no images.
  B - branded manufactured product. The 2.7x cheese-tortellini spread (141 to 376 cal per 100 g)
      lives here and nowhere else. Only this class needs a browser.
  C - the row cannot move a serving. Provenance for tidiness, and it must never consume Class B
      effort just because it is frequent - salt appears in 514 recipes and carries no macros at all.

CLASS C IS MEASURED, NOT NAMED. An earlier draft of this file listed the spices by hand, which is a
judgement dressed as a rule and would have put "Ranch Seasoning Mix" wherever the author's mood put
it. What is computed instead is the MOST calories this row contributes to ONE SERVING of any live
recipe: grams_in_recipe / servings * (calories / serving_grams). Under TRIVIAL_CAL_PER_SERVING a
100% brand error moves less than that many calories on a ~500 calorie serving, so a label chase
cannot pay for itself. Black pepper computes 9.3 and lands in C on its own; so does hot sauce at 0.0,
and so does every dried herb. That is the plan's "4 g in a 14-serving batch cannot move a number",
run as arithmetic.

ORDERING IS BY GRAMS, NEVER BY RECIPE COUNT. Tortellini at 4,424 g across 3 recipes outranks garlic
powder across 95, because a label only matters where the grams are.

THE GRANDFATHER LIST IS THE POINT OF THE GATE. `source` is now MANDATORY for any row that is not on
the frozen 2026-08-26 legacy list. That list can only ever be worked down; nothing may be added to
it, and a new row that cites nobody is refused. Without the frozen list the gate could only be "all
376 rows must be sourced", which is a gate that is red on the day it ships and therefore no gate.
"""
from __future__ import annotations

import glob
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
MP = os.path.dirname(HERE)
DB_PATH = os.path.join(MP, "food-macros-db.json")
SPEC_DIR = os.path.join(MP, "db", "recipes")
CLASSES_PATH = os.path.join(MP, "db", "food-provenance-classes.json")
LEGACY_PATH = os.path.join(MP, "db", "food-provenance-legacy.json")
REPORT_PATH = os.path.join(MP, "db", "food-provenance-report.md")

# A recipe is LIVE when it is on the site. Both values ship; `draft` and anything else does not.
LIVE_VISIBILITY = ("paid", "public")

# Under this, a 100% brand error moves less than 10 calories on a serving that averages ~500. See
# the module docstring: this is what makes Class C measured rather than named.
TRIVIAL_CAL_PER_SERVING = 10.0

# BRANDED MANUFACTURED PRODUCTS - the only judgement call left in the classifier, and it is a
# judgement about the FOOD, not about this DB's numbers: is the formulation the manufacturer's
# (so two brands are two different foods), or is it the ingredient's (so USDA's curated entry is the
# better reference)? Sauces, mixes, cured and seasoned meats, and engineered products are the first.
# Plain durum pasta, lean-ratio ground meat, canned plain vegetables and single-ingredient dairy are
# the second - USDA curates those to a tighter tolerance than a store label states them.
MANUFACTURED = frozenset([
    "Alfredo Sauce", "Achiote Paste", "BBQ Sauce", "BBQ Sauce (Sugar Free)", "Beef Broth",
    "Berbere Seasoning", "Buffalo Wing Sauce", "Butter Crackers", "Cajun Seasoning",
    "Cheese Tortellini", "Chicken Broth", "Chili Crisp", "Chili Crisp / Chili Oil",
    "Chipotle in Adobo", "Coconut Milk", "Corn Chips", "Corn Muffin Mix", "Curry Powder",
    "Diced Green Chiles", "Diced Tomatoes & Green Chilies", "Dijon Mustard", "Dill Pickles",
    "Enchilada Sauce", "Fajita Seasoning", "Fish Sauce", "Five-Spice Powder", "Fries",
    "Frozen Hash Browns", "Garam Masala", "Gochujang", "Harissa Paste", "Hickory Smoked Bacon",
    "High Fiber Tortilla", "Hoisin Sauce", "Honey Dijon Mustard", "Hot Honey", "Hot Italian Sausage",
    "Hot Sauce", "Hummus", "Italian Seasoning", "Japanese Curry Roux", "Ketchup", "Keto Bun",
    "Lemongrass Paste", "Lo Mein Noodles", "Marinara Sauce", "Mexican Cheese Blend", "Milk",
    "Mirin", "Mole Paste", "Oyster Sauce", "Peanut Butter", "Penne Pasta", "Pepperoncini",
    "Pomegranate Molasses", "Pork Chorizo", "Potato Gnocchi", "Ranch Seasoning Mix",
    "Red Curry Paste", "Refrigerated Biscuits", "Rice Noodles", "Rotini Pasta", "Salsa",
    "Salsa Verde", "Seasoned Black Beans", "Smoked Turkey Sausage", "Soy Sauce", "Sriracha",
    "Sugar-Free Maple Syrup", "Taco Seasoning", "Teriyaki Sauce", "Tortilla", "Traditional Pasta Sauce",
    "Turkey Pepperoni", "Worcestershire Sauce", "Zero-Sugar Soda",
])


def load_db(path=None):
    with open(path or DB_PATH, "r", encoding="utf-8-sig") as f:
        return json.load(f)


def has_source(row):
    return bool(str(row.get("source") or "").strip())


def unsourced(db):
    return [r for r in db.get("items", []) if isinstance(r, dict) and r.get("item")
            and not has_source(r)]


def usage(db, spec_dir=None):
    """Per item: total grams across LIVE recipes, how many live recipes name it, and the most
    calories it puts into ONE SERVING of any of them.

    THE MAX, NOT THE MEAN. A row that is a rounding error in 90 recipes and a third of the calories
    in the 91st is not a trivial row, and averaging would say it was."""
    by_name = {}
    for r in db.get("items", []):
        if isinstance(r, dict) and r.get("item"):
            by_name[str(r["item"])] = r
    out = {}
    n_live = 0
    for path in sorted(glob.glob(os.path.join(spec_dir or SPEC_DIR, "*.json"))):
        try:
            with open(path, "r", encoding="utf-8-sig") as f:
                spec = json.load(f)
        except Exception:                                          # noqa: BLE001
            continue
        if spec.get("visibility") not in LIVE_VISIBILITY:
            continue
        n_live += 1
        servings = float(spec.get("servings") or 0)
        for line in (spec.get("ingredients_grams") or []):
            name = str(line.get("item") or "")
            grams = float(line.get("grams") or 0)
            if not name:
                continue
            rec = out.setdefault(name, {"grams": 0.0, "recipes": 0, "max_cal_per_serving": 0.0})
            rec["grams"] += grams
            rec["recipes"] += 1
            row = by_name.get(name)
            sg = float((row or {}).get("serving_grams") or 0)
            cal = float((row or {}).get("calories") or 0)
            if row and sg > 0 and servings > 0:
                per = grams / servings * (cal / sg)
                if per > rec["max_cal_per_serving"]:
                    rec["max_cal_per_serving"] = per
    return out, n_live


def classify(row, use):
    """(class, why). `use` is this row's usage record, or None when no live recipe names it."""
    name = str(row.get("item") or "")
    branded = name in MANUFACTURED
    if not use or use["recipes"] == 0:
        # UNUSED IS NOT TRIVIAL. A row no live recipe names contributes 0 calories to every serving,
        # and calling that "cannot move a number" would file a branded sauce as tidy-up on the
        # strength of nobody cooking it this month. It is classified by what the FOOD is, and the
        # grams ordering keeps it at the bottom of the worklist where it belongs.
        return ("B" if branded else "A"), "no live recipe names it; classified by the food"
    per = use["max_cal_per_serving"]
    if per < TRIVIAL_CAL_PER_SERVING:
        return "C", ("at most %.1f cal in one serving - under %.0f, so a 100%% brand error cannot "
                     "move a serving" % (per, TRIVIAL_CAL_PER_SERVING))
    if branded:
        return "B", ("branded manufactured: the formulation is the maker's, and it reaches %.0f cal "
                     "in a serving" % per)
    return "A", ("generic whole food or commodity staple, %.0f cal in a serving at most; USDA "
                 "curated is the better reference" % per)


def classify_all(db=None, spec_dir=None):
    db = db if db is not None else load_db()
    use, n_live = usage(db, spec_dir)
    rows = []
    for row in unsourced(db):
        name = str(row["item"])
        u = use.get(name)
        cls, why = classify(row, u)
        rows.append({
            "item": name,
            "brand": str(row.get("brand") or ""),
            "class": cls,
            "why": why,
            "grams_live": round((u or {}).get("grams", 0.0), 1),
            "recipes_live": (u or {}).get("recipes", 0),
            "max_cal_per_serving": round((u or {}).get("max_cal_per_serving", 0.0), 2),
            "note_states_origin": _note_origin(row),
        })
    rows.sort(key=lambda r: (-r["grams_live"], r["item"]))
    return {"generated": "2026-08-26", "live_recipes": n_live, "rows": rows}


def _note_origin(row):
    """Does this row's free-text `notes` ALREADY say where the numbers came from?

    Measured over the 204 the day this shipped: most of them do - "R100 verified: Great Value
    Mayonnaise label", "USDA FDC raw carrot", "from label". That is provenance sitting in prose where
    no tool can read it, which is a different problem from provenance that does not exist, and the
    report must not conflate them. It is a HINT, never a source: nothing here promotes a note into
    the `source` field."""
    n = str(row.get("notes") or "").lower()
    if "fdc" in n or "usda" in n:
        return "usda"
    if "label" in n:
        return "label"
    return ""


# ---- the gate: `source` is mandatory for every row that is not grandfathered -----------------------

def legacy_names(path=None):
    p = path or LEGACY_PATH
    if not os.path.exists(p):
        return None
    with open(p, "r", encoding="utf-8-sig") as f:
        doc = json.load(f)
    return set(str(x) for x in (doc.get("unsourced_at_freeze") or []))


def source_violations(db=None, legacy=None, legacy_path=None):
    """Rows carrying no `source` that the frozen list does not excuse. Empty means the gate is green.

    A CANNOT-RUN IS NOT A CLEAN BILL. A missing legacy file returns a violation saying so, rather
    than an empty list that reads as "every row is sourced"."""
    db = db if db is not None else load_db()
    names = legacy_names(legacy_path) if legacy is None else legacy
    if names is None:
        return ["CANNOT RUN: %s is missing, so no row can be judged grandfathered"
                % os.path.relpath(LEGACY_PATH, MP)]
    out = []
    for row in unsourced(db):
        name = str(row["item"])
        if name not in names:
            out.append("food-DB row %r carries no `source`. Every row added after the 2026-08-26 "
                       "freeze must name where its numbers came from - an FDC id, a retailer URL, "
                       "or an explicitly-labelled proxy." % name)
    return out


def render_report(doc):
    rows = doc["rows"]
    by = {"A": [], "B": [], "C": []}
    for r in rows:
        by[r["class"]].append(r)
    out = []
    w = out.append
    w("# Food-DB provenance: the %d unsourced rows, classified" % len(rows))
    w("")
    w("Generated by `meal-prep\\pipeline\\food_provenance.py --report`, rung 1 of "
      "`design\\PLAN-food-db-provenance-2026-08-26.md`. Usage is measured over the %d live "
      "(`paid`/`public`) recipe specs." % doc["live_recipes"])
    w("")
    w("| class | rows | what it means | who answers it |")
    w("|---|---|---|---|")
    w("| A | %d | generic whole food or commodity staple | USDA FDC curated, unattended |"
      % len(by["A"]))
    w("| B | %d | branded manufactured product | the retailer's own label photo |" % len(by["B"]))
    w("| C | %d | cannot move a serving (< %.0f cal) | provenance for tidiness only |"
      % (len(by["C"]), TRIVIAL_CAL_PER_SERVING))
    w("")
    already = sum(1 for r in rows if r["note_states_origin"])
    w("**%d of the %d already state an origin in free-text `notes`** (\"R100 verified: Great Value "
      "Mayonnaise label\", \"USDA FDC raw carrot\"). That is provenance sitting in prose where no "
      "tool can read it - a different problem from provenance that does not exist. Nothing in this "
      "run promotes a note into `source`." % (already, len(rows)))
    w("")
    w("## Class B, by grams in live recipes - this is the rung-4 worklist")
    w("")
    w("Ordered by GRAMS, not recipe count: a label only matters where the grams are.")
    w("")
    w("| # | row | brand | grams (live) | recipes | max cal/serving | notes say |")
    w("|---|---|---|---|---|---|---|")
    for i, r in enumerate(by["B"], 1):
        w("| %d | %s | %s | %s | %d | %.0f | %s |"
          % (i, r["item"], r["brand"] or "-", "{:,.0f}".format(r["grams_live"]), r["recipes_live"],
             r["max_cal_per_serving"], r["note_states_origin"] or "-"))
    w("")
    for cls, title in (("A", "Class A - FDC curated, unattended (rung 2)"),
                       ("C", "Class C - cannot move a serving")):
        w("## %s" % title)
        w("")
        w("| row | grams (live) | recipes | max cal/serving |")
        w("|---|---|---|---|")
        for r in by[cls]:
            w("| %s | %s | %d | %.1f |" % (r["item"], "{:,.0f}".format(r["grams_live"]),
                                           r["recipes_live"], r["max_cal_per_serving"]))
        w("")
    return "\n".join(out) + "\n"


# ---- selftest ---------------------------------------------------------------------------------

def _row(name, cal=100.0, sg=100.0, source=None):
    r = {"item": name, "serving_grams": sg, "serving_qty": 1, "serving_unit": "serving",
         "calories": cal, "protein_g": 1, "carbs_g": 1, "fat_g": 1}
    if source is not None:
        r["source"] = source
    return r


def _fake_use(grams=1000.0, recipes=3, per=50.0):
    return {"grams": grams, "recipes": recipes, "max_cal_per_serving": per}


def selftest():
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    # MUST FIRE: the gate rung 1 exists to install. A row added after the freeze that cites nobody
    # is REFUSED - "Atwater proves four numbers agree with each other, never that they are this
    # food's numbers", and the daemon already refuses this at write; this is the same rule applied
    # to the file as it stands, so a row that arrives by hand is caught too.
    db = {"items": [_row("Legacy Onion"), _row("Brand New Sauce"),
                    _row("Sourced Thing", source="fdc:12345")]}
    v = source_violations(db, legacy={"Legacy Onion"})
    T("MUST FIRE  a row added after the freeze with no `source` is a violation",
      len(v) == 1 and "Brand New Sauce" in v[0], json.dumps(v)[:200])
    T("CLEAN TWIN a grandfathered unsourced row is NOT a violation - the freeze list is a worklist, "
      "not a debt the gate calls in on day one",
      all("Legacy Onion" not in x for x in v), json.dumps(v)[:200])
    T("CLEAN TWIN a row that cites a source passes",
      all("Sourced Thing" not in x for x in v), json.dumps(v)[:200])
    # MUST FIRE: a could-not-look is not a clean bill.
    cr = source_violations(db, legacy_path=os.path.join(HERE, "no-such-legacy-file.json"))
    T("MUST FIRE  a missing legacy file is a CANNOT RUN, not an empty violation list - a gate that "
      "could not look must never read as three sourced rows",
      len(cr) == 1 and "CANNOT RUN" in cr[0], json.dumps(cr)[:200])

    # MUST FIRE: Class C is MEASURED. Black pepper is in 491 recipes and cannot move a serving.
    cls, why = classify(_row("Black Pepper"), _fake_use(grams=2782, recipes=491, per=9.3))
    T("MUST FIRE  a row in 491 recipes that reaches 9.3 cal in a serving is C - frequency is not "
      "difficulty", cls == "C", "%s: %s" % (cls, why))
    cls, why = classify(_row("Cheese Tortellini"), _fake_use(grams=4424, recipes=3, per=180))
    T("MUST FIRE  a branded product in 3 recipes that reaches 180 cal in a serving is B - the 2.7x "
      "spread lives here", cls == "B", "%s: %s" % (cls, why))
    cls, _ = classify(_row("Yellow Onion"), _fake_use(grams=130891, recipes=369, per=25))
    T("CLEAN TWIN a generic whole food stays A no matter how frequent - an onion is an onion",
      cls == "A", cls)
    # MUST FIRE: the trivial rule must not swallow a branded row that DOES move a serving.
    cls, _ = classify(_row("Marinara Sauce"), _fake_use(per=TRIVIAL_CAL_PER_SERVING + 0.1))
    T("MUST FIRE  a branded row just over the trivial line is B, not C", cls == "B", cls)
    cls, _ = classify(_row("Marinara Sauce"), _fake_use(per=TRIVIAL_CAL_PER_SERVING - 0.1))
    T("CLEAN TWIN the same branded row just under it is C", cls == "C", cls)
    # MUST FIRE: unused is not trivial.
    cls, why = classify(_row("Mole Paste"), _fake_use(grams=0, recipes=0, per=0.0))
    T("MUST FIRE  a row NO live recipe names is classified by the food, not filed as trivial - 0 "
      "calories because nobody cooked it is not the same claim as 0 calories per serving",
      cls == "B", "%s: %s" % (cls, why))

    # The max, not the mean: one heavy recipe decides.
    fake_db = {"items": [_row("Heavy", cal=100.0, sg=100.0)]}
    import tempfile                                                # noqa: PLC0415
    tmp = tempfile.mkdtemp(prefix="foodprov-")
    try:
        specs = [("light", 14, 14.0), ("heavy", 14, 1400.0)]
        for slug, sv, g in specs:
            with open(os.path.join(tmp, slug + ".json"), "w", encoding="utf-8") as f:
                json.dump({"slug": slug, "visibility": "paid", "servings": sv,
                           "ingredients_grams": [{"item": "Heavy", "grams": g}]}, f)
        use, n = usage(fake_db, spec_dir=tmp)
        T("MUST FIRE  usage takes the MAX per-serving contribution, not the mean - a row that is a "
          "rounding error in 90 recipes and a third of the 91st is not trivial",
          abs(use["Heavy"]["max_cal_per_serving"] - 100.0) < 0.01 and n == 2,
          json.dumps(use))
        with open(os.path.join(tmp, "draft.json"), "w", encoding="utf-8") as f:
            json.dump({"slug": "draft", "visibility": "draft", "servings": 14,
                       "ingredients_grams": [{"item": "Heavy", "grams": 99999}]}, f)
        use2, n2 = usage(fake_db, spec_dir=tmp)
        T("CLEAN TWIN a spec that is not live does not count toward grams or the max",
          n2 == 2 and use2["Heavy"]["grams"] == use["Heavy"]["grams"], "%d %s" % (n2, json.dumps(use2)))
    finally:
        import shutil                                              # noqa: PLC0415
        shutil.rmtree(tmp, ignore_errors=True)

    print("%d assertion(s) failed" % len(bad) if bad else "all assertions passed")
    return 1 if bad else 0


if __name__ == "__main__":
    import sys

    if "--selftest" in sys.argv:
        raise SystemExit(selftest())
    if "--gate" in sys.argv:
        vs = source_violations()
        for v in vs:
            print("  X     " + v)
        print("  ok    every food-DB row outside the 2026-08-26 freeze names a source"
              if not vs else "%d violation(s)" % len(vs))
        raise SystemExit(1 if vs else 0)
    if "--freeze" in sys.argv:
        names = sorted(str(r["item"]) for r in unsourced(load_db()))
        with open(LEGACY_PATH, "w", encoding="utf-8") as f:
            json.dump({"readme": "The food-DB rows carrying no `source` at the 2026-08-26 freeze. "
                                 "This list may only ever SHRINK - a row leaves it by gaining a "
                                 "source. Nothing may be added: a new row that cites nobody is "
                                 "refused by food_provenance.py --gate.",
                       "frozen": "2026-08-26", "count": len(names),
                       "unsourced_at_freeze": names}, f, ensure_ascii=False, indent=1)
        print("froze %d unsourced row name(s) -> %s" % (len(names), LEGACY_PATH))
        raise SystemExit(0)
    doc = classify_all()
    counts = {}
    for r in doc["rows"]:
        counts[r["class"]] = counts.get(r["class"], 0) + 1
    if "--report" in sys.argv:
        with open(CLASSES_PATH, "w", encoding="utf-8") as f:
            json.dump(doc, f, ensure_ascii=False, indent=1)
        with open(REPORT_PATH, "w", encoding="utf-8") as f:
            f.write(render_report(doc))
        print("classified %d unsourced row(s) over %d live recipes: %s"
              % (len(doc["rows"]), doc["live_recipes"], json.dumps(counts, sort_keys=True)))
        print("  -> %s" % CLASSES_PATH)
        print("  -> %s" % REPORT_PATH)
        raise SystemExit(0)
    print(json.dumps(counts, sort_keys=True))
    raise SystemExit(0)
