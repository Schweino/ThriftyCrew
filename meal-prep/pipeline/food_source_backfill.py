"""food_source_backfill.py - give the generic rows a citation, unattended, without touching a number.

RUNG 2 of design\\PLAN-food-db-provenance-2026-08-26.md. For Class A - generic whole foods and
commodity staples - USDA's curated SR Legacy and Foundation entries are BETTER than a store label,
not a fallback: an onion is an onion, and USDA curates it to a tighter tolerance than any retailer
prints. So the citation for those rows can be fetched by a machine with no browser and no images.

THE ONE RULE THIS FILE EXISTS TO OBEY: IT WRITES `source` AND NOTHING ELSE. Not calories, not
protein, not the serving basis. The tortellini lesson is the whole reason - the single unsourced row
this estate hand-audited against a photographed label was EXACTLY right, and the mapper's proposed
replacement (307 cal / 13.5 g protein per 100 g against a true 175 / 5.8) was worse. A backfill that
felt free to "correct" rows would have made the DB worse while reporting 98 rows improved.

SO WHAT DOES A DISAGREEING CANDIDATE MEAN? It means one of two things and this tool cannot tell them
apart: the stored row is wrong, or the candidate is a different food. Either way the answer is the
same - REPORT IT, write nothing, and let a person look. Disagreements land in
db\\food-source-review.md, which is a file, not a line in a run's findings that scrolls away.

AND AGREEMENT IS THE IDENTITY EVIDENCE. fdc_lookup's doctrine is that picking WHICH candidate is the
food is a frontier call, measured 37% false locally. This tool does not overturn that; it uses a
weaker claim that a machine can make honestly: when a curated candidate whose description matches the
food's own name reproduces the four numbers this DB already holds, that candidate is a citation FOR
THOSE NUMBERS whether or not it is the perfect entry. That is why the written string says
"corroborates" and never "fetched" - these numbers did not come from FDC, and a source line claiming
they did would be a fabrication of history.

THE SEARCH TERM COMES OFF THE ROW'S OWN NOTES FIRST. 194 of the 204 unsourced rows already state an
origin in prose, and ~50 of them name the FDC food outright - "NEW wave90 (per 100g). USDA FDC raw
carrot". Asking FDC for "raw carrot" beats asking it for "Carrots", which is exactly the lesson
fdc_lookup learned with parsley: the problem was the question, not the ranking.
"""
from __future__ import annotations

import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import fdc_lookup                                                  # noqa: E402
import food_provenance as fp                                       # noqa: E402

MP = fp.MP
REVIEW_PATH = os.path.join(MP, "db", "food-source-review.md")
APPROVALS_PATH = os.path.join(MP, "db", "food-source-approvals.json")
CAPTURES_PATH = os.path.join(MP, "db", "food-label-captures.json")
CHECKED = "2026-08-26"

# TOLERANCE, STATED. Both rows are put on per-100-g before anything is compared - the H2 lesson from
# the conflict rule, where 10 of 13 "conflicts" were a per-100-g row held against a household one and
# every single one was the same food.
#   calories: 10% or 15 kcal per 100 g, whichever is larger
#   each macro: 15% or 2 g per 100 g, whichever is larger
# The absolute floors exist because a percentage is meaningless near zero - 0.4 g of fat against 0.9
# is 125% apart and is not a disagreement about what the food is.
CAL_REL, CAL_ABS = 0.10, 15.0
MACRO_REL, MACRO_ABS = 0.15, 2.0

# Curated only. Branded is the RIGHT answer for Class B and a weak one for Class A, and letting a
# branded row corroborate a generic one is how a house-brand label becomes the citation for "onion".
CURATED = ("SR Legacy", "Foundation")


def per_100g(row):
    sg = float(row.get("serving_grams") or 0)
    if sg <= 0:
        return None
    f = 100.0 / sg
    out = {}
    for k in ("calories", "protein_g", "carbs_g", "fat_g"):
        v = row.get(k)
        if not isinstance(v, (int, float)):
            return None
        out[k] = float(v) * f
    return out


def cand_100g(cand):
    m = cand.get("macros") or {}
    if "calories" not in m:
        return None
    return {"calories": float(m.get("calories") or 0.0),
            "protein_g": float(m.get("protein_g") or 0.0),
            "carbs_g": float(m.get("carbs_g") or 0.0),
            "fat_g": float(m.get("fat_g") or 0.0)}


def _apart(a, b, rel, absolute):
    return abs(a - b) > max(absolute, rel * max(abs(a), abs(b)))


def compare(stored, cand):
    """([fields that disagree], readable per-100-g text). Empty list = corroborated."""
    off = []
    if _apart(stored["calories"], cand["calories"], CAL_REL, CAL_ABS):
        off.append("calories")
    for k in ("protein_g", "carbs_g", "fat_g"):
        if _apart(stored[k], cand[k], MACRO_REL, MACRO_ABS):
            off.append(k)
    text = ("stored %.0f cal / %.1f P / %.1f C / %.1f F  vs  FDC %.0f / %.1f / %.1f / %.1f  "
            "(per 100 g)" % (stored["calories"], stored["protein_g"], stored["carbs_g"],
                             stored["fat_g"], cand["calories"], cand["protein_g"],
                             cand["carbs_g"], cand["fat_g"]))
    return off, text


def _clean_term(t):
    """FDC's search endpoint answers 400 to a query carrying a slash or a stray bracket, and 11 of
    the first 145 terms this tool built did exactly that - "93/7 Ground Beef",
    "Beef Flank/Sirloin Steak", "Korean glass noodles (dangmyeon)". A 400 is a term this tool
    malformed, NOT a food FDC does not carry, and the two must never look the same in a report."""
    t = re.sub(r"\([^)]*\)", " ", str(t or ""))
    t = t.replace("/", " ").replace("&", " and ")
    t = re.sub(r"[^A-Za-z0-9,\-' ]+", " ", t)
    return " ".join(t.split()).strip(" ,-")


def search_terms(row):
    """The row's own note first, then its name. Never more than three - each is an API call."""
    terms = []
    notes = str(row.get("notes") or "")
    m = re.search(r"USDA\s+FDC\s+([^.;\[\]]+)", notes, re.I)
    if m:
        t = _clean_term(m.group(1))
        # A NUMBER IS NOT A SEARCH TERM. Several notes read "USDA FDC 170926 via myfooddata", and
        # asking FDC's free-text search for "170926 via myfooddata" is asking it nothing.
        if t and len(t) > 2 and not re.match(r"^\d+\b", t):
            terms.append(t)
    name = _clean_term(row.get("item"))
    if name and name.lower() not in [x.lower() for x in terms]:
        terms.append(name)
    # A trailing plural or a comma-form often is the difference between a curated hit and nothing.
    if name.lower().endswith("s") and len(name) > 4:
        terms.append(name[:-1])
    return [t for t in terms[:3] if t]


def gather(rows, opener=None, key=None, log=None, pause=0.2):
    """Fill the shared FDC cache for every term these rows need. One pass, cached, no re-asking."""
    terms = []
    for r in rows:
        terms.extend(search_terms(r))
    seen, uniq = set(), []
    for t in terms:
        k = t.lower()
        if k not in seen:
            seen.add(k)
            uniq.append(t)
    return fdc_lookup.cache_fill(uniq, page_size=4, opener=opener, key=key, pause=pause, log=log)


def candidates_for(row, cache=None):
    out = []
    for t in search_terms(row):
        ent = fdc_lookup.cache_get(t, cache=cache) or {}
        for c in (ent.get("candidates") or []):
            if c.get("data_type") in CURATED:
                out.append((t, c))
    return out


def approvals(path=None):
    """WHICH FDC ENTRY IS THIS FOOD - a frontier ruling, read from a file, never inferred here.

    The first mechanical pass over the live shelves is why this exists. Taking the top CORROBORATING
    candidate wrote Croutons for "Bread Crumbs", rice cakes for "Rice", chicken BREAST for "Boneless
    Skinless Chicken Thigh" and a peanut CANDY BAR for "Peanuts" - every one of them inside tolerance
    on all four macros. Agreement is necessary and it is nowhere near sufficient, which is exactly
    fdc_lookup's own doctrine: gathering is mechanical, identity is not."""
    with open(path or APPROVALS_PATH, "r", encoding="utf-8-sig") as f:
        doc = json.load(f)
    return doc.get("approved") or {}, doc.get("rejected") or {}


def candidate_by_id(fdc_id, cache=None):
    """Find one FDC candidate anywhere in the shared cache, whatever term put it there.

    A ruling may name an entry the ROW'S OWN terms never returned - "Pasta, dry, enriched" is the
    right citation for Ziti, Orzo, Fettuccine, Spaghetti and both Shells rows, and only two of those
    terms ever surfaced it."""
    c = cache if cache is not None else fdc_lookup.cache_read()
    for ent in (c.get("terms") or {}).values():
        for cand in (ent.get("candidates") or []):
            if str(cand.get("fdc_id")) == str(fdc_id):
                return cand
    return None


def adjudicate(row, cache=None, approved=None, rejected=None):
    """One row's verdict.

      CORROBORATED - an approved FDC entry, and the numbers still agree. This is the only verdict
                     that writes anything.
      DISAGREES    - an approved entry whose numbers do NOT agree. Reported, never written: the
                     stored row may be right and the entry wrong, and this tool cannot tell.
      REJECTED     - a ruling that says no curated entry is this food, with the reason.
      UNRULED      - nobody has ruled on this row yet. Not a pass, not a failure: a worklist item.

    THE TWO TESTS ARE INDEPENDENT AND BOTH MUST HOLD. Approval is about identity; tolerance is about
    numbers. An approved id whose macros drifted is a report, not a licence."""
    if approved is None or rejected is None:
        approved, rejected = approvals()
    name = str(row.get("item") or "")
    if name in rejected:
        return {"verdict": "REJECTED", "why": rejected[name]}
    ruling = approved.get(name)
    if not ruling:
        return {"verdict": "UNRULED", "why": "no identity ruling in food-source-approvals.json"}
    stored = per_100g(row)
    if stored is None:
        return {"verdict": "DISAGREES", "off": ["basis"],
                "why": "the stored row has no usable per-100-g basis", "text": ""}
    cand = candidate_by_id(ruling.get("fdc_id"), cache)
    if cand is None:
        return {"verdict": "DISAGREES", "off": ["missing"],
                "why": "FDC %s is not in the cache - run --gather" % ruling.get("fdc_id"),
                "text": "", "fdc_id": ruling.get("fdc_id")}
    if cand.get("data_type") not in CURATED:
        return {"verdict": "DISAGREES", "off": ["data_type"],
                "why": "FDC %s is a %s row, and Branded may not cite a generic"
                       % (ruling.get("fdc_id"), cand.get("data_type")),
                "text": "", "fdc_id": ruling.get("fdc_id")}
    cm = cand_100g(cand)
    off, text = compare(stored, cm)
    rec = {"fdc_id": cand.get("fdc_id"), "data_type": cand.get("data_type"),
           "description": cand.get("description"), "off": off, "text": text,
           "proxy": bool(ruling.get("proxy")), "why": ruling.get("why", "")}
    if off:
        rec["verdict"] = "DISAGREES"
        return rec
    rec["verdict"] = "CORROBORATED"
    lead = ("PROXY - USDA FDC %s (%s) %s standing in; %s"
            % (cand.get("fdc_id"), cand.get("data_type"), cand.get("description"),
               ruling.get("why") or "no exact curated entry exists")
            if ruling.get("proxy") else
            "USDA FDC %s (%s) %s" % (cand.get("fdc_id"), cand.get("data_type"),
                                     cand.get("description")))
    rec["source"] = "%s; corroborates the stored row within tolerance, checked %s" % (lead, CHECKED)
    return rec


# ---- rung 4: labels photographed in Brad's Chrome ------------------------------------------------

def label_captures(path=None):
    """The panels read off the product photographs, keyed by food-DB row name.

    THE PANEL IS A PHOTOGRAPH AND THAT IS THE WHOLE DIFFICULTY. Walmart's page text does not carry
    it, __NEXT_DATA__ carries only a collapsed NutritionValuePlaceholder, and the image URLs are
    hashed with empty alt text - so no regex finds the label and no automated client even reaches the
    page (WebFetch gets the bot wall; Brad's Chrome gets the product). These were transcribed by eye,
    household measure AND grams, per the meal-macro standard."""
    with open(path or CAPTURES_PATH, "r", encoding="utf-8-sig") as f:
        doc = json.load(f)
    return dict((str(c["item"]), c) for c in (doc.get("captures") or []) if c.get("item"))


def label_per_100g(cap):
    """A captured panel on the per-100-g basis, or None when the panel states no gram weight.

    A LABEL IN MILLILITRES IS NOT A LABEL IN GRAMS, and pretending otherwise is how a broth row gets
    scaled by a density nobody measured. Where the panel states only mL - broth, soy sauce, coconut
    milk - the serving_g field carries the gram weight the STORED row already uses for that same
    household measure, which is what makes the two comparable at all; where they disagree about the
    measure itself, the capture is a CONFLICT and never a corroboration."""
    lab = cap.get("label") or {}
    g = lab.get("serving_g")
    if not isinstance(g, (int, float)) or g <= 0:
        return None
    f = 100.0 / float(g)
    out = {}
    for k in ("calories", "protein_g", "carbs_g", "fat_g"):
        v = lab.get(k)
        if not isinstance(v, (int, float)):
            return None
        out[k] = float(v) * f
    return out


def adjudicate_label(row, cap):
    """Same contract as the FDC path: CORROBORATED writes a `source` and nothing else; anything that
    does not agree is REPORTED. status LABEL and PROXY are the only ones that can ever write."""
    st = str(cap.get("status") or "")
    if st in ("UNFOUND", "CONFLICT"):
        return {"verdict": st, "why": cap.get("note", ""), "product": cap.get("product"),
                "url": cap.get("url")}
    stored = per_100g(row)
    lab100 = label_per_100g(cap)
    if stored is None or lab100 is None:
        return {"verdict": "CONFLICT", "off": ["basis"],
                "why": "the panel or the stored row states no usable gram weight",
                "product": cap.get("product"), "url": cap.get("url")}
    off, text = compare(stored, lab100)
    rec = {"off": off, "text": text, "product": cap.get("product"), "url": cap.get("url"),
           "why": cap.get("note", ""), "proxy": st == "PROXY"}
    if off:
        rec["verdict"] = "CONFLICT"
        return rec
    lab = cap["label"]
    lead = ("PROXY - %s" % cap.get("product")) if st == "PROXY" else str(cap.get("product"))
    rec["verdict"] = "CORROBORATED"
    rec["source"] = ("%s label, read off the product photograph in Brad's Chrome %s (%s): %s, "
                     "%s cal / %s g fat / %s g carb / %s g protein%s. %s"
                     % (lead, CHECKED, cap.get("url"), lab.get("serving"), lab.get("calories"),
                        lab.get("fat_g"), lab.get("carbs_g"), lab.get("protein_g"),
                        (", %s servings per container" % lab["servings_per_container"])
                        if lab.get("servings_per_container") is not None else "",
                        cap.get("note", "")))
    return rec


def run_labels(write=False, db_path=None, captures=None, log=print):
    db = fp.load_db(db_path)
    caps = captures if captures is not None else label_captures()
    by_name = {}
    results = []
    for row in db.get("items", []):
        cap = caps.get(str(row.get("item") or ""))
        if not cap:
            continue
        v = adjudicate_label(row, cap)
        v["item"] = str(row["item"])
        results.append(v)
        if v["verdict"] == "CORROBORATED" and not fp.has_source(row):
            by_name[v["item"]] = v["source"]
    # A capture naming a row the DB does not hold is a FINDING, not a silent no-op.
    for name in caps:
        if not any(r["item"] == name for r in results):
            results.append({"item": name, "verdict": "CONFLICT",
                            "why": "no food-DB row is named %r" % name, "off": ["no such row"]})
    if write:
        n = 0
        for row in db["items"]:
            src = by_name.get(str(row.get("item") or ""))
            if src and not fp.has_source(row):
                row["source"] = src
                n += 1
        _write_db(db, db_path)
        log("wrote `source` on %d row(s) from photographed labels; NOTHING ELSE was touched" % n)
    return results


def run(write=False, only_class=("A",), db_path=None, cache=None, log=print):
    db = fp.load_db(db_path)
    doc = fp.classify_all(db)
    want = {r["item"] for r in doc["rows"] if r["class"] in only_class}
    rows = [r for r in fp.unsourced(db) if str(r["item"]) in want]
    app, rej = approvals()
    results = []
    for row in rows:
        v = adjudicate(row, cache, app, rej)
        v["item"] = str(row["item"])
        results.append(v)
    if write:
        by_name = {}
        for v in results:
            if v["verdict"] == "CORROBORATED":
                by_name[v["item"]] = v["source"]
        n = 0
        for row in db["items"]:
            s = by_name.get(str(row.get("item") or ""))
            if s and not fp.has_source(row):
                row["source"] = s
                n += 1
        _write_db(db, db_path)
        log("wrote `source` on %d row(s); NOTHING ELSE was touched" % n)
    return results


def _write_db(db, path=None):
    p = path or fp.DB_PATH
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(db, f, ensure_ascii=False, indent=1)
    os.replace(tmp, p)


def render_review(results, classes):
    def pick(v):
        return [r for r in results if r["verdict"] == v]

    ok, dis, rej, unr = pick("CORROBORATED"), pick("DISAGREES"), pick("REJECTED"), pick("UNRULED")
    prox = [r for r in ok if r.get("proxy")]

    def g(item):
        return classes.get(item, {}).get("grams_live", 0)

    def gt(item):
        return "{:,.0f}".format(g(item))

    out = []
    w = out.append
    w("# Food-DB source backfill: what FDC would and would not confirm")
    w("")
    w("Rung 2 of `design\\PLAN-food-db-provenance-2026-08-26.md`, run %s. %d row(s) put to USDA's "
      "curated tiers: **%d corroborated** (%d of them as a stated proxy), **%d disagreed**, "
      "**%d ruled to have no curated entry**, **%d not yet ruled on**."
      % (CHECKED, len(results), len(ok), len(prox), len(dis), len(rej), len(unr)))
    w("")
    w("**Nothing on this page was overwritten, and nothing was written on a machine's guess.** Two "
      "independent tests must both hold before a `source` is written: a frontier ruling that this "
      "FDC entry IS this food (`db\\food-source-approvals.json`), and the stored numbers still "
      "agreeing with it. The first pass without the ruling proposed Croutons for Bread Crumbs, rice "
      "cakes for Rice and chicken BREAST for chicken thigh - all four macros inside tolerance.")
    w("")
    w("Tolerance: calories %.0f%% or %.0f kcal per 100 g, whichever is larger; each macro %.0f%% or "
      "%.0f g." % (CAL_REL * 100, CAL_ABS, MACRO_REL * 100, MACRO_ABS))
    w("")
    w("## Disagreed - an approved entry whose numbers do not match. A person decides.")
    w("")
    if not dis:
        w("None.")
    else:
        w("| row | grams (live) | FDC entry | off by | numbers |")
        w("|---|---|---|---|---|")
        for r in sorted(dis, key=lambda x: -g(x["item"])):
            w("| %s | %s | FDC %s %s | %s | %s |"
              % (r["item"], gt(r["item"]), r.get("fdc_id"),
                 (r.get("description") or r.get("why") or "")[:52],
                 ", ".join(r.get("off") or []), r.get("text", "")))
    w("")
    w("## No curated entry is this food - these need a label (rung 4) or a stated proxy")
    w("")
    if not rej:
        w("None.")
    else:
        for r in sorted(rej, key=lambda x: -g(x["item"])):
            w("- **%s** (%s g live) - %s" % (r["item"], gt(r["item"]), r["why"]))
    w("")
    w("## Corroborated as a PROXY - visibly not the real thing, which is the point")
    w("")
    if not prox:
        w("None.")
    else:
        for r in prox:
            w("- **%s** - FDC %s %s. %s"
              % (r["item"], r.get("fdc_id"), r.get("description"), r.get("why", "")))
    w("")
    if unr:
        w("## Not yet ruled on")
        w("")
        for r in sorted(unr, key=lambda x: -g(x["item"])):
            w("- **%s** (%s g live)" % (r["item"], gt(r["item"])))
        w("")
    return "\n".join(out) + "\n"


def render_label_review(results, classes):
    def pick(v):
        return [r for r in results if r["verdict"] == v]

    ok, con, unf = pick("CORROBORATED"), pick("CONFLICT"), pick("UNFOUND")

    def g(item):
        return classes.get(item, {}).get("grams_live", 0)

    out = []
    w = out.append
    w("# Class B labels, photographed in Brad's Chrome")
    w("")
    w("Rung 4 of `design\\PLAN-food-db-provenance-2026-08-26.md`, %s. %d row(s) attempted: "
      "**%d corroborated and cited**, **%d disagreed with the stored row**, **%d unfound**."
      % (CHECKED, len(results), len(ok), len(con), len(unf)))
    w("")
    w("The panel is a PHOTOGRAPH in the product image carousel. It is not in the page text, not in "
      "`__NEXT_DATA__` (which holds only a collapsed `NutritionValuePlaceholder`), and no filename "
      "or alt-text regex finds it. An automated fetch of the same URL returns a bot wall.")
    w("")
    w("## Cited from the photograph")
    w("")
    for r in sorted(ok, key=lambda x: -g(x["item"])):
        w("- **%s** (%s g live)%s - %s" % (r["item"], "{:,.0f}".format(g(r["item"])),
                                           " *(proxy)*" if r.get("proxy") else "", r.get("product")))
    if not ok:
        w("None.")
    w("")
    w("## The panel disagrees with the stored row - nothing was written")
    w("")
    for r in sorted(con, key=lambda x: -g(x["item"])):
        w("- **%s** (%s g live) - %s. %s %s"
          % (r["item"], "{:,.0f}".format(g(r["item"])), r.get("product") or "-",
             r.get("text", ""), r.get("why", "")))
    if not con:
        w("None.")
    w("")
    w("## Unfound - recorded, not retried forever")
    w("")
    for r in sorted(unf, key=lambda x: -g(x["item"])):
        w("- **%s** (%s g live) - %s" % (r["item"], "{:,.0f}".format(g(r["item"])), r.get("why", "")))
    if not unf:
        w("None.")
    w("")
    return "\n".join(out) + "\n"


# ---- selftest ---------------------------------------------------------------------------------

def _row(name, sg=100.0, cal=100.0, p=5.0, c=10.0, f=2.0, notes=""):
    return {"item": name, "serving_grams": sg, "serving_qty": 1, "serving_unit": "serving",
            "calories": cal, "protein_g": p, "carbs_g": c, "fat_g": f, "notes": notes}


def _cache(term, cands):
    return {"terms": {term: {"asked": True, "candidates": cands}}}


def _cand(fid, desc, cal, p, c, f, dt="SR Legacy"):
    return {"fdc_id": fid, "description": desc, "data_type": dt, "brand": None,
            "basis": "per 100 g", "portions": [],
            "macros": {"calories": cal, "protein_g": p, "carbs_g": c, "fat_g": f}}


def selftest():
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    APP = {"Dried Basil": {"fdc_id": 171317},
           "Cheese Tortellini": {"fdc_id": 9},
           "Carrots": {"fdc_id": 2},
           "Yellow Onion": {"fdc_id": 5},
           "Green Onions": {"fdc_id": 6, "proxy": True, "why": "tops only, not the whole onion"},
           "Cabbage": {"fdc_id": 7},
           "Heavy Cream": {"fdc_id": 8},
           "Ghost Food": {"fdc_id": 99999}}
    REJ = {"Rice": "the curated shelf returns rice CAKES, not rice"}

    # MUST FIRE: the basis is normalised before anything is called different. A household row held
    # against a per-100-g one is the SAME CLAIM, and 10 of 13 live "conflicts" were exactly this.
    cache = _cache("dried basil", [_cand(171317, "Spices, basil, dried", 233, 23, 28, 3)])
    v = adjudicate(_row("Dried Basil", sg=1.0, cal=2.33, p=0.23, c=0.28, f=0.03), cache, APP, REJ)
    T("MUST FIRE  a 1 g household row and a per-100-g FDC row are put on ONE basis before they are "
      "compared - 2.33 per gram IS 233 per 100 g", v["verdict"] == "CORROBORATED",
      json.dumps(v)[:200])

    # MUST FIRE: the tortellini shape - an approved id whose numbers drifted is a REPORT, not a
    # licence. Approval is identity; tolerance is numbers; both must hold independently.
    tc = _cache("cheese tortellini", [_cand(9, "Pasta, fresh-refrigerated, spinach, cooked",
                                            307, 13.5, 45, 4)])
    v = adjudicate(_row("Cheese Tortellini", sg=120.0, cal=210, p=7, c=38, f=2.5), tc, APP, REJ)
    T("MUST FIRE  an APPROVED entry reading 307/13.5 against a stored 175/5.8 per 100 g still "
      "DISAGREES and writes nothing - approval is identity, not a licence over the numbers",
      v["verdict"] == "DISAGREES" and "calories" in v["off"], json.dumps(v)[:200])

    # MUST FIRE: the whole reason this file grew an approvals table. Numbers alone are not identity.
    cc = _cache("carrots", [_cand(1, "Croutons, plain", 41, 0.9, 9.6, 0.2),
                            _cand(2, "Carrots, raw", 41, 0.93, 9.58, 0.24)])
    v = adjudicate(_row("Carrots", sg=100.0, cal=41, p=0.9, c=9.6, f=0.2), cc, APP, REJ)
    T("MUST FIRE  a corroborating candidate that is the WRONG FOOD is not written - the ruling names "
      "the entry, and a perfectly agreeing Croutons row is still Croutons",
      v["verdict"] == "CORROBORATED" and v["fdc_id"] == 2, json.dumps(v)[:200])

    # MUST FIRE: an unruled row is a worklist item, never a silent pass.
    v = adjudicate(_row("Gochujang"), {"terms": {}}, APP, REJ)
    T("MUST FIRE  a row nobody has ruled on is UNRULED, never a pass - a lookup that could not "
      "answer is not a clean bill", v["verdict"] == "UNRULED", json.dumps(v)[:160])
    v = adjudicate(_row("Rice"), {"terms": {}}, APP, REJ)
    T("CLEAN TWIN a row RULED to have no curated entry carries its reason forward",
      v["verdict"] == "REJECTED" and "rice CAKES" in v["why"], json.dumps(v)[:160])

    # MUST FIRE: Branded may not cite a generic, even when approved and agreeing.
    bc = _cache("yellow onion", [_cand(5, "ONIONS", 40, 1.1, 9.3, 0.1, dt="Branded")])
    v = adjudicate(_row("Yellow Onion", sg=100.0, cal=40, p=1.1, c=9.3, f=0.1), bc, APP, REJ)
    T("MUST FIRE  a Branded row may not corroborate a Class A generic - that is how a house-brand "
      "label becomes the citation for an onion",
      v["verdict"] == "DISAGREES" and v["off"] == ["data_type"], json.dumps(v)[:200])

    # MUST FIRE: an approved id the cache does not hold is a CANNOT-RUN, not a pass.
    v = adjudicate(_row("Ghost Food"), {"terms": {}}, APP, REJ)
    T("MUST FIRE  an approved id that is not in the cache is reported, never silently skipped",
      v["verdict"] == "DISAGREES" and v["off"] == ["missing"], json.dumps(v)[:160])

    # CLEAN TWIN: the absolute floors. 0.4 g fat against 0.9 is 125% apart and is not a disagreement.
    v = adjudicate(_row("Cabbage", sg=100.0, cal=25, p=1.3, c=5.8, f=0.4),
                   _cache("cabbage", [_cand(7, "Cabbage, raw", 25, 1.28, 5.8, 0.9)]), APP, REJ)
    T("CLEAN TWIN the absolute floor holds near zero - 0.4 g of fat against 0.9 is 125% apart and is "
      "not a disagreement about what the food is", v["verdict"] == "CORROBORATED",
      json.dumps(v)[:200])
    v = adjudicate(_row("Heavy Cream", sg=100.0, cal=340, p=2.8, c=2.8, f=36.0),
                   _cache("heavy cream",
                          [_cand(8, "Cream, fluid, heavy whipping", 340, 2.8, 2.8, 30.0)]),
                   APP, REJ)
    T("MUST FIRE  the relative test still bites well away from zero - 36 g of fat against 30 is a "
      "real disagreement", v["verdict"] == "DISAGREES" and v["off"] == ["fat_g"],
      json.dumps(v)[:200])

    # MUST FIRE: a proxy must SAY it is a proxy. Rung 3 of the ladder is honest or it is nothing.
    pc = _cache("green onions", [_cand(6, "Onions, young green, tops only", 27, 1.0, 5.7, 0.5)])
    v = adjudicate(_row("Green Onions", sg=100.0, cal=27, p=1.0, c=5.7, f=0.5), pc, APP, REJ)
    T("MUST FIRE  a proxy row's source SAYS PROXY and names what is standing in for what - a proxy "
      "that does not announce itself is worse than no source at all",
      v["verdict"] == "CORROBORATED" and v["source"].startswith("PROXY - USDA FDC 6"),
      repr(v.get("source"))[:180])

    # MUST FIRE: a ruling may name an entry the row's own search terms never returned.
    far = {"terms": {"ziti pasta": {"asked": True,
                                    "candidates": [_cand(2, "Carrots, raw", 41, 0.93, 9.58, 0.24)]}}}
    v = adjudicate(_row("Carrots", sg=100.0, cal=41, p=0.9, c=9.6, f=0.2), far, APP, REJ)
    T("MUST FIRE  a ruling may cite an entry that this row's OWN terms never returned - one Pasta, "
      "dry, enriched row is the right citation for five pasta rows and only two terms surfaced it",
      v["verdict"] == "CORROBORATED" and v["fdc_id"] == 2, json.dumps(v)[:200])

    # MUST FIRE: the search term comes off the row's own note.
    t = search_terms(_row("Carrots", notes="NEW wave90 (per 100g). USDA FDC raw carrot"))
    T("MUST FIRE  the row's own note names the FDC food and is asked FIRST - raw carrot beats "
      "Carrots, which is the parsley lesson", t[0] == "raw carrot", json.dumps(t))
    num = search_terms(_row("Carrots", notes="USDA FDC 170926 via myfooddata"))
    T("MUST FIRE  a note reading 'USDA FDC 170926 via myfooddata' is not asked as a search term - a "
      "number is not a question", num[0] == "Carrots", json.dumps(num))
    T("MUST FIRE  a slash or a bracket is scrubbed out of a term - FDC answers 400 to those, and a "
      "400 is a term this tool malformed, NOT a food FDC does not carry",
      search_terms(_row("93/7 Ground Beef"))[0] == "93 7 Ground Beef"
      and search_terms(_row("Korean glass noodles (dangmyeon)"))[0] == "Korean glass noodles",
      json.dumps(search_terms(_row("93/7 Ground Beef"))))

    # MUST FIRE: run(write=True) writes `source` and NOTHING else.
    import tempfile                                                # noqa: PLC0415
    tmpd = tempfile.mkdtemp(prefix="fsb-")
    try:
        dbp = os.path.join(tmpd, "db.json")
        appp = os.path.join(tmpd, "approvals.json")
        before = {"readme": "x", "items": [_row("Carrots", sg=100.0, cal=41, p=0.9, c=9.6, f=0.2,
                                                notes="USDA FDC raw carrot")]}
        with open(dbp, "w", encoding="utf-8") as f:
            json.dump(before, f)
        with open(appp, "w", encoding="utf-8") as f:
            json.dump({"approved": {"Carrots": {"fdc_id": 2}}, "rejected": {}}, f)
        cache2 = _cache("raw carrot", [_cand(2, "Carrots, raw", 41, 0.93, 9.58, 0.24)])
        real_classify, real_app = fp.classify_all, globals()["APPROVALS_PATH"]
        fp.classify_all = lambda db=None, spec_dir=None: {
            "generated": CHECKED, "live_recipes": 0,
            "rows": [{"item": "Carrots", "class": "A", "grams_live": 0, "recipes_live": 0}]}
        globals()["APPROVALS_PATH"] = appp
        try:
            run(write=True, only_class=("A",), db_path=dbp, cache=cache2, log=lambda *_a: None)
        finally:
            fp.classify_all = real_classify
            globals()["APPROVALS_PATH"] = real_app
        with open(dbp, "r", encoding="utf-8-sig") as f:
            after = json.load(f)["items"][0]
        moved = [k for k in ("calories", "protein_g", "carbs_g", "fat_g", "serving_grams",
                             "serving_qty", "serving_unit", "notes")
                 if after.get(k) != before["items"][0].get(k)]
        T("MUST FIRE  the backfill writes `source` and NOTHING else - not a calorie, not a basis",
          not moved and str(after.get("source", "")).startswith("USDA FDC 2 (SR Legacy)"),
          "moved=%s source=%r" % (json.dumps(moved), after.get("source")))
        T("MUST FIRE  the written string says CORROBORATES, never fetched - these numbers did not "
          "come from FDC and a source line claiming they did would fabricate their history",
          "corroborates" in str(after.get("source", "")), repr(after.get("source"))[:160])
    finally:
        import shutil                                              # noqa: PLC0415
        shutil.rmtree(tmpd, ignore_errors=True)

    # ---- rung 4: labels photographed in Brad's Chrome ------------------------------------------

    def cap(item, status="LABEL", cal=100, p_=5, c_=10, f_=2, g=100, **kw):
        d = {"item": item, "status": status, "product": "Great Value Fixture, 12 oz",
             "url": "https://www.walmart.com/ip/1", "note": "fixture",
             "label": {"serving": "1 cup (%sg)" % g, "servings_per_container": 4, "calories": cal,
                       "fat_g": f_, "carbs_g": c_, "protein_g": p_, "serving_g": g}}
        d.update(kw)
        return d

    v = adjudicate_label(_row("Fixture Broth", sg=240.0, cal=10, p=1, c=0, f=0),
                         cap("Fixture Broth", cal=10, p_=1, c_=0, f_=0, g=240))
    T("MUST FIRE  a photographed panel that reproduces the stored row is cited, and the citation "
      "names the photograph and the URL - not the page, which does not carry the label at all",
      v["verdict"] == "CORROBORATED" and "read off the product photograph" in v["source"]
      and "walmart.com" in v["source"], json.dumps(v)[:240])

    v = adjudicate_label(_row("Fixture Coconut", sg=80.0, cal=140, p=1, c=2, f=14),
                         cap("Fixture Coconut", cal=120, p_=1, c_=2, f_=12, g=80))
    T("MUST FIRE  a panel that DISAGREES with the stored row writes nothing, even when the capture "
      "was filed as a clean LABEL - the transcription is a claim, not a licence",
      v["verdict"] == "CONFLICT" and "calories" in v["off"], json.dumps(v)[:200])

    v = adjudicate_label(_row("Fixture Sausage"), cap("Fixture Sausage", status="UNFOUND"))
    T("MUST FIRE  a label that could not be found is RECORDED as unfound and writes nothing - never "
      "retried forever, never silently skipped", v["verdict"] == "UNFOUND", json.dumps(v)[:160])

    v = adjudicate_label(_row("Fixture Broth", sg=240.0, cal=10, p=1, c=0, f=0),
                         cap("Fixture Broth", status="PROXY", cal=10, p_=1, c_=0, f_=0, g=240))
    T("MUST FIRE  a capture of a DIFFERENT brand's package says PROXY in the field itself - the row "
      "states Swanson and the shelf carries Great Value, and a citation that hides that is worse "
      "than none", v["verdict"] == "CORROBORATED" and v["source"].startswith("PROXY - "),
      repr(v.get("source"))[:200])

    nog = cap("Fixture Broth", g=240)
    nog["label"].pop("serving_g")
    v = adjudicate_label(_row("Fixture Broth", sg=240.0), nog)
    T("MUST FIRE  a panel stating only millilitres cannot corroborate a row stated in grams - "
      "inventing the density is how a broth row gets scaled by a number nobody measured",
      v["verdict"] == "CONFLICT" and v["off"] == ["basis"], json.dumps(v)[:200])

    import tempfile                                                # noqa: PLC0415
    tmp3 = tempfile.mkdtemp(prefix="fsb-lab-")
    try:
        dbp = os.path.join(tmp3, "db.json")
        before = {"readme": "x", "items": [_row("Fixture Broth", sg=240.0, cal=10, p=1, c=0, f=2,
                                                notes="keep me")]}
        with open(dbp, "w", encoding="utf-8") as f:
            json.dump(before, f)
        caps = {"Fixture Broth": cap("Fixture Broth", cal=10, p_=1, c_=0, f_=2, g=240),
                "Ghost Row": cap("Ghost Row")}
        res = run_labels(write=True, db_path=dbp, captures=caps, log=lambda *_a: None)
        with open(dbp, "r", encoding="utf-8-sig") as f:
            after = json.load(f)["items"][0]
        moved = [k for k in ("calories", "protein_g", "carbs_g", "fat_g", "serving_grams",
                             "serving_qty", "serving_unit", "notes")
                 if after.get(k) != before["items"][0].get(k)]
        T("MUST FIRE  the label pass writes `source` and NOTHING else - the tortellini lesson holds "
          "for a photograph exactly as it holds for an FDC row",
          not moved and "read off the product photograph" in str(after.get("source", "")),
          "moved=%s source=%r" % (json.dumps(moved), str(after.get("source"))[:90]))
        ghost = [r for r in res if r["item"] == "Ghost Row"]
        T("MUST FIRE  a capture naming a row the DB does not hold is a FINDING, not a silent no-op - "
          "a transcription with nowhere to land must not vanish",
          len(ghost) == 1 and ghost[0]["verdict"] == "CONFLICT", json.dumps(ghost)[:200])
    finally:
        import shutil                                              # noqa: PLC0415
        shutil.rmtree(tmp3, ignore_errors=True)

    print("%d assertion(s) failed" % len(bad) if bad else "all assertions passed")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(selftest())
    classes_doc = fp.classify_all()
    classes = {r["item"]: r for r in classes_doc["rows"]}
    only = ("A",)
    for i, a in enumerate(sys.argv):
        if a == "--class" and i + 1 < len(sys.argv):
            only = tuple(x.strip().upper() for x in sys.argv[i + 1].split(","))
    rows = [r for r in fp.unsourced(fp.load_db()) if classes.get(str(r["item"]), {}).get("class") in only]
    if "--gather" in sys.argv:
        st = gather(rows, log=print)
        print("FDC cache: added %(added)d, already had %(skipped)d, could not run %(failed)d, "
              "now holds %(size)d term(s)" % st)
        raise SystemExit(2 if st["failed"] and not st["added"] else 0)
    if "--labels" in sys.argv:
        res = run_labels(write="--write" in sys.argv)
        tally = {}
        for r in res:
            tally[r["verdict"]] = tally.get(r["verdict"], 0) + 1
        with open(os.path.join(MP, "db", "food-label-review.md"), "w", encoding="utf-8") as f:
            f.write(render_label_review(res, classes))
        print("photographed labels: %d row(s) -> %s" % (len(res), json.dumps(tally, sort_keys=True)))
        raise SystemExit(0)
    res = run(write="--write" in sys.argv, only_class=only)
    tally = {}
    for r in res:
        tally[r["verdict"]] = tally.get(r["verdict"], 0) + 1
    if "--review" in sys.argv or "--write" in sys.argv:
        with open(REVIEW_PATH, "w", encoding="utf-8") as f:
            f.write(render_review(res, classes))
        print("  -> %s" % REVIEW_PATH)
    print("class %s: %d row(s) offered to FDC curated -> %s"
          % (",".join(only), len(res), json.dumps(tally, sort_keys=True)))
    raise SystemExit(0)
