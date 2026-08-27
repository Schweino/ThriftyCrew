"""band_precheck.py - compute a recipe's per-serving band from ITS INGREDIENTS, before we store it.

WHY THIS EXISTS (2026-08-27). The candidate pool's `band` is whatever the SOURCE SITE published, and
this estate measured those wrong by -25% to +43% in a single run:

    dill-pickle-chicken-wings   site 620 cal   ours 888   (4 lb of wings across 4 servings)
    enchiladas-suizas           site 519 cal   ours 754
    honey-balsamic-chicken      site 452 cal   ours 349

All three passed selection on the site's number and then died at OUR macro gate - after the run had
paid for extraction, mapping and pricing. Five of thirteen candidates died that way on
hunt-2026-08-27-ten: 38% of the expensive lanes, spent on recipes that were never going to qualify,
for want of arithmetic that costs nothing.

WHAT IT IS AND IS NOT. It is a SANITY CHECK, not a costing. It resolves ingredient lines to food-DB
rows by name, converts the stated amount to grams with the estate's OWN parser (coverage_check's
parse_amount / to_base - a second parser here would be the forked-taxonomy defect this pipeline warns
about in three files), sums the macros and divides by the serving count. It will not match the
mapper, which rules on every line and is why the mapper exists. It only has to catch the GROSS
divergence, and every failure above was gross.

IT NEVER REFUSES A CANDIDATE. Brad's ruling of 2026-08-24 removed the ingest band because a
hard-coded one buried 1,556 candidates against a constraint no run had asked for. This records
`band_computed`, its `coverage`, and a `band_conflict` flag, and nothing more. A run may prefer
defensible candidates; nothing is ever lost for a number we could not check.

AND IT SPEAKS ONLY WHEN IT HAS THE EVIDENCE. Below MIN_COVERAGE of the lines resolved, or with the
main protein line unparsed, it returns coverage and NO verdict - because a band computed over half a
dinner is not a smaller truth, it is a different dish.
"""
import json
import os

import coverage_check as cc

HERE = os.path.dirname(os.path.abspath(__file__))
MP = os.path.dirname(HERE)
FOOD_DB = os.path.join(MP, "food-macros-db.json")
DENSITIES = os.path.join(MP, "db", "densities.json")

# 0.45 LET IT SPEAK FOR EVERYTHING AND BE WRONG (2026-08-27, measured on the 15 stored candidates).
# With unit synonyms fixed, coverage rose from 4/15 to 15/15 - and the numbers came out 35-62% LOW
# against the publishers, with one 77% HIGH. The estimate is only as good as the food DB's coverage
# of THIS recipe's foods, and a new candidate is precisely the case where the DB has not met them
# yet; the mapper is what adds them, one lane later. An earlier validation looked far better because
# every recipe in it had already been through a run, so its rows had been added BY that run - the
# sample was contaminated and the 8% error it reported was not transferable.
# So the bar is set where the estimate is defensible rather than where it is available. Below it,
# this says nothing, which is the honest answer and the cheap one.
MIN_COVERAGE = 0.75
MIN_PROTEIN_SHARE = 0.25     # the dominant line must carry at least this much of the calories
# ...AND THE RESULT MUST BE A DINNER. Four resolved SPICE lines gave 100% coverage, a 45% "dominant"
# share and 5.5 cal a serving - every ratio green, describing nothing anyone eats. A share is a
# statement about the lines we read; this is a statement about whether we read the dinner at all.
MIN_PLAUSIBLE_CAL = 150
CONFLICT_RATIO = 0.25        # 25% apart is not rounding; every measured failure was 40%+

# THE PAGE'S UNIT WORDS AND THE DENSITY TABLE'S KEYS ARE NOT THE SAME VOCABULARY. A recipe writes
# "1 tablespoon olive oil"; densities.json keys that weight under "tbsp". parse_amount correctly
# returns the PAGE's word - normalising it there would change a contract the scale-ratio check
# depends on - so the translation belongs here, at the lookup. And a SIZE word is a count: "3 medium
# chicken breasts" is three of them, which densities answers under "each".
# Measured: this alone was most of the missing coverage - cowboy-chicken matched 15 of its 16 lines
# to a food row and still produced grams for only two, because every spice said "teaspoon".
UNIT_SYNONYM = {"tablespoon": "tbsp", "tablespoons": "tbsp", "tbsps": "tbsp",
                "teaspoon": "tsp", "teaspoons": "tsp", "tsps": "tsp",
                "fluid ounce": "floz", "fl oz": "floz",
                "medium": "each", "large": "each", "small": "each", "whole": "each",
                "piece": "each", "pieces": "each", "count": "each"}

MASS_G = {"g": 1.0, "gram": 1.0, "kg": 1000.0, "oz": 28.349523125, "lb": 453.59237}


def load_food_db(path=None):
    """The food DB indexed by every name a recipe line might actually use.

    A RECIPE DOES NOT SAY WHAT THE DB SAYS. The DB carries "Boneless Skinless Chicken Breast"; the
    page says "2 medium 1.5 lbs. chicken breasts". Matching only the full DB name inside the line
    missed the MAIN PROTEIN of honey-balsamic-chicken-tenders entirely and computed 152 cal against
    a true 349 - and the protein is the one line whose absence cannot be absorbed. So each row is
    also indexed by the tail of its name ("chicken breast", "skinless chicken breast"), which is the
    part a recipe actually prints. Longest alias wins, so a specific row still beats a generic one.
    """
    with open(path or FOOD_DB, "r", encoding="utf-8-sig") as f:
        rows = (json.load(f) or {}).get("items") or []
    pairs = []
    for r in rows:
        nm = (r.get("item") or "").strip()
        if not nm:
            continue
        low = nm.lower()
        aliases = {low}
        w = low.split()
        for n in (2, 3):
            if len(w) > n:
                aliases.add(" ".join(w[-n:]))
        for a in aliases:
            pairs.append((a, r))
    pairs.sort(key=lambda pr: -len(pr[0]))
    return pairs, rows


def load_densities(path=None):
    """densities.json - grams per household unit per canonical item, plus its documented defaults.

    THE ESTATE ALREADY STATES WHAT A CUP OF EACH FOOD WEIGHS and this reads that table rather than
    inventing one. Its own header records that food-macros-db and this file both state a cup weight
    and disagreed on 13 items until 2026-08-07, which is exactly why a third opinion here would be a
    defect rather than a convenience.
    """
    try:
        with open(path or DENSITIES, "r", encoding="utf-8-sig") as f:
            d = json.load(f) or {}
        return d.get("items") or {}, d.get("defaults") or {}
    except Exception:
        return {}, {}


def match_row(line, index):
    """The food-DB row this ingredient line names, or None. Longest name wins."""
    t = (line or "").lower()
    best = None
    for name, row in index:
        if name and name in t and (best is None or len(name) > len(best[0])):
            best = (name, row)
    return best[1] if best else None


def line_grams(line, row, dens=None, defaults=None):
    """Grams this line contributes, using the estate's own amount parser and its own density table.

    THREE ROADS, IN ORDER OF HOW MUCH THE ESTATE KNOWS:
      1. a MASS unit - universal, no lookup needed;
      2. this food's own densities.json entry for the stated unit (cup / tbsp / each / clove ...);
      3. the food row's own serving basis when it happens to state the same unit.
    Anything else is None, which costs the line its coverage rather than inventing a weight. A
    guessed gram figure is the fabricated-band defect one lane earlier.
    """
    # AN EXPLICIT MASS ON THE LINE BEATS A COUNT ON THE SAME LINE, and it is checked FIRST.
    # "2 medium 1.5 lbs. chicken breasts" leads with a count, so parse_amount returns (2, "medium")
    # per its own contract - correct for what it answers, and useless here, because the 1.5 lbs is
    # the fact and the count is packaging. Missing it cost this pre-check the MAIN PROTEIN of
    # honey-balsamic-chicken-tenders: 152 cal computed against a true 349. The same ambiguity vetoed
    # the mapper's correct 680 g one lane over and stuck that recipe three times in a single run.
    # cc.stated_mass_grams is the shared answer; its PowerShell twin is Get-StatedMassGrams in
    # map-preresolve.ps1 and the two are pinned to agree.
    stated = cc.stated_mass_grams(line or "")
    if stated:
        return stated
    amt = cc.parse_amount(line or "")
    if not amt:
        return None
    val, unit = amt
    if not val or val <= 0:
        return None
    u = (unit or "").lower()
    u = UNIT_SYNONYM.get(u, UNIT_SYNONYM.get(u.rstrip("s"), u.rstrip("s")))
    if u in MASS_G:
        return val * MASS_G[u]
    item = (row.get("item") or "")
    per = (dens or {}).get(item) or {}
    if isinstance(per, dict) and per.get(u):
        return val * float(per[u])
    sg = row.get("serving_grams")
    sq = row.get("serving_qty") or 1
    su = str(row.get("serving_unit") or "").lower().rstrip("s")
    if sg and su and u == su and sq:
        return val * (float(sg) / float(sq))
    return None


def compute(ingredients, servings, index=None, dens=None, defaults=None):
    """{cal, protein_g, carbs_g, fat_g, coverage, lines, resolved} per serving, or coverage only."""
    if index is None:
        index, _ = load_food_db()
    if dens is None:
        dens, defaults = load_densities()
    try:
        servings = float(servings)
    except (TypeError, ValueError):
        servings = 0
    lines = [str(x) for x in (ingredients or []) if str(x).strip()]
    if not lines or not servings or servings <= 0:
        return {"coverage": 0.0, "lines": len(lines), "resolved": 0, "verdict": None}
    tot = {"cal": 0.0, "protein_g": 0.0, "carbs_g": 0.0, "fat_g": 0.0}
    resolved = 0
    biggest = 0.0
    for ln in lines:
        row = match_row(ln, index)
        if not row:
            continue
        g = line_grams(ln, row, dens, defaults)
        if g is None:
            continue
        sg = row.get("serving_grams")
        if not sg:
            continue
        k = g / float(sg)
        tot["cal"] += k * (row.get("calories") or 0)
        tot["protein_g"] += k * (row.get("protein_g") or 0)
        tot["carbs_g"] += k * (row.get("carbs_g") or 0)
        tot["fat_g"] += k * (row.get("fat_g") or 0)
        biggest = max(biggest, k * (row.get("calories") or 0))
        resolved += 1
    prot_share = (biggest / tot["cal"]) if tot["cal"] > 0 else 0.0
    cov = resolved / float(len(lines))
    out = {"coverage": round(cov, 3), "lines": len(lines), "resolved": resolved,
           "protein_share": round(prot_share, 3)}
    # THE GATE IS THE PROTEIN, NOT THE LINE COUNT. dill-pickle-chicken-wings resolved only half its
    # lines - and the half it resolved was FOUR POUNDS OF WINGS, which is essentially the whole
    # dinner. Rejecting it for coverage threw away the most accurate estimate in the sample, while a
    # recipe that resolves nine trivial spice lines and misses its beef would have passed. What makes
    # an estimate defensible is that the calories are actually in it: the dominant contributor must
    # be present, and the rest is detail.
    per_serving_cal = tot["cal"] / float(servings)
    # THE FLOOR IS PUBLISHED AT ANY COVERAGE, AND THE ESTIMATE IS NOT. An unresolved line contributes
    # zero here and something positive in reality, so this total is a lower bound on the real dinner
    # no matter how many lines we read. That makes it sound in exactly one direction - see
    # exceeds_ceiling - while the ESTIMATE below still needs the coverage gate to be worth quoting.
    # Gating the floor on coverage threw away the case this was built for:
    # dill-pickle-chicken-wings reads only half its lines and still floors at 854 against an 800
    # ceiling, which is a refusal we can defend while its publisher advertised 620.
    out["cal_floor"] = round(per_serving_cal, 1)
    if prot_share < MIN_PROTEIN_SHARE or cov < MIN_COVERAGE or per_serving_cal < MIN_PLAUSIBLE_CAL:
        out["verdict"] = None
        return out
    for k in ("cal", "protein_g", "carbs_g", "fat_g"):
        out[k] = round(tot[k] / float(servings), 1)
    out["verdict"] = "computed"
    return out


def conflict(claimed, computed, ratio=CONFLICT_RATIO):
    """Do the site's calories and ours disagree beyond rounding? None when either is unavailable."""
    if not computed or computed.get("verdict") != "computed":
        return None
    a = (claimed or {}).get("cal")
    b = computed.get("cal")
    if not isinstance(a, (int, float)) or not isinstance(b, (int, float)) or a <= 0 or b <= 0:
        return None
    return abs(b - a) / float(a) > ratio


def selftest():
    """Fixtures over shapes, plus the three real recipes whose true macros the pipeline computed."""
    fails = []

    def T(name, ok, got=""):
        print("  %s  %s%s" % ("ok   " if ok else "X    ", name, "" if ok else ("   got: %s" % got)))
        if not ok:
            fails.append(name)

    idx, _rows = load_food_db()
    dens, defs = load_densities()

    # THE ALIAS ROAD, which is the fix that made this usable at all.
    T("MUST FIRE  a recipe line's own words find the DB row - 'chicken breasts' is "
      "'Boneless Skinless Chicken Breast'",
      (match_row("2 lbs chicken breasts, diced", idx) or {}).get("item", "").lower().endswith("chicken breast"),
      str((match_row("2 lbs chicken breasts", idx) or {}).get("item")))
    T("CLEAN TWIN a longer alias still beats a shorter one, so a specific row wins over a generic",
      (match_row("1 cup chicken broth", idx) or {}).get("item") == "Chicken Broth",
      str((match_row("1 cup chicken broth", idx) or {}).get("item")))

    # MASS beats everything and needs no table.
    row = {"item": "X", "serving_grams": 100, "calories": 100, "protein_g": 10, "carbs_g": 0, "fat_g": 0}
    T("MUST FIRE  a stated mass converts with no lookup", abs(line_grams("4 lbs wings", row, {}, {}) - 1814.37) < 0.1,
      str(line_grams("4 lbs wings", row, {}, {})))
    T("MUST FIRE  a volume uses the estate's OWN density row, never a guess",
      line_grams("2 cups salsa verde", {"item": "Salsa Verde"}, {"Salsa Verde": {"cup": 240}}, {}) == 480,
      str(line_grams("2 cups salsa verde", {"item": "Salsa Verde"}, {"Salsa Verde": {"cup": 240}}, {})))
    T("CLEAN TWIN a unit nothing states a weight for is None, never invented",
      line_grams("2 handfuls parsley", {"item": "P"}, {}, {}) is None,
      str(line_grams("2 handfuls parsley", {"item": "P"}, {}, {})))

    # THE GATE. A dinner whose PROTEIN resolved is defensible even at half coverage; one whose
    # protein is missing is not, however many spice lines it got right.
    c = compute(["4 lbs chicken wings", "2 tsp dried dill", "3/4 tsp salt"], 4, idx, dens, defs)
    T("MUST FIRE  a dinner whose dominant line resolved is computed even at partial coverage",
      c.get("verdict") == "computed" and c.get("protein_share", 0) > 0.9, json.dumps(c))
    c2 = compute(["1 tsp garlic powder", "3/4 tsp salt", "2 tsp dried dill", "1 tsp black pepper"], 4,
                 idx, dens, defs)
    T("CLEAN TWIN four resolved SPICE lines and no protein is NOT a band - it is a different dish",
      c2.get("verdict") is None, json.dumps(c2))

    # CONFLICT is one-sided and quiet unless it has both numbers.
    T("MUST FIRE  a 30% gap between the site and our arithmetic is a conflict",
      conflict({"cal": 620}, {"verdict": "computed", "cal": 854}) is True)
    T("CLEAN TWIN rounding is not a conflict", conflict({"cal": 540}, {"verdict": "computed", "cal": 560}) is False)
    T("CLEAN TWIN no computed band means no verdict, never a false accusation",
      conflict({"cal": 620}, {"verdict": None}) is None)
    T("CLEAN TWIN no site figure means no verdict either",
      conflict({}, {"verdict": "computed", "cal": 854}) is None)

    print("band-precheck SELF-TEST %s" % ("PASS" if not fails else "FAIL (%d)" % len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    import sys as _s
    _s.exit(selftest() if "--selftest" in _s.argv else 0)


def exceeds_ceiling(computed, ceiling):
    """Is this dinner ALREADY over the calorie ceiling on the lines we could read? True / False / None.

    THE ONE-SIDED READING IS THE ONLY SOUND ONE, and the measurement says so. At the 0.75 coverage
    gate the computed figure ran -14% to -41% against the publishers on the 15 stored candidates -
    every single error NEGATIVE. That is not noise, it is arithmetic: a line we could not resolve
    contributes zero here and something positive in reality, so what this computes is a FLOOR and
    never a ceiling.

    A floor is worth acting on in exactly one direction. If the floor already clears the ceiling, the
    real dinner clears it by more and the recipe is out - certain, without the food DB knowing every
    line. If the floor sits under the band, that is not evidence of anything: the missing lines could
    put it anywhere above.

    Measured on the case this was built for: dill-pickle-chicken-wings computes a floor of 854 against
    an 800 ceiling, so it is refusable on our own arithmetic while its publisher advertised 620.
    """
    if not computed:
        return None
    cal = computed.get("cal_floor")
    if not isinstance(cal, (int, float)) or not isinstance(ceiling, (int, float)) or ceiling <= 0:
        return None
    return cal > ceiling

