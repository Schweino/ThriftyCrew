r"""audit_transcription_fidelity.py - is the recipe we transcribed the recipe the page states?

    python meal-prep/pipeline/audit_transcription_fidelity.py --run <run-dir>   # a whole run
    python meal-prep/pipeline/audit_transcription_fidelity.py --file <one.json> # one transcription
    python meal-prep/pipeline/audit_transcription_fidelity.py --selftest        # hermetic

WHY THIS EXISTS (2026-09-07, backlog E9's open half). E9 asked whether a cheaper model could do the
extraction; the head-to-head refused the swap, and the finding worth keeping was different: **nothing
compares a transcription to the page it came from.** `recipe-source-qa` rules whether the BUILT
recipe matches the TRANSCRIPTION - one link downstream of where drift happens - so a transcription
that quietly normalised, dropped or invented a line passes every check we run, and the built card
faithfully reproduces the wrong thing.

THE QUANTITY IS THE PART THAT COSTS MONEY. A dropped adjective is a fidelity nit. A quantity that
moved is a price on a live paid page: "1 pound" transcribed as "1 cup" reprices the whole card. So
the numbers are compared strictly and the prose is compared loosely, which is the opposite of what a
naive text diff does.

AND THE EXTRACTOR IS NOT VERBATIM ON PURPOSE - it normalises unicode fractions and strips
parentheticals ([[extractor-raw-is-not-verbatim]]). A checker that did not know that would flag every
line on every page and be switched off within a day, so those two transformations are normalised on
BOTH sides before anything is compared. That is the calibration this file lives or dies on, and it is
what the must-not-fire fixtures pin.

A PAGE WE CANNOT READ IS NEVER CLEAN. No JSON-LD, a 403, a paywall, a redirect to a listing - each is
reported as CANNOT-CHECK against its own count. "We checked 40 recipes and found nothing" and "we
could read 3 of 40" are different sentences and this file will not let them print the same.

NETWORK, SO NOT IN run-gates. Its pure half is hermetic and discovered by the --selftest pass; the
live half reads the open web and belongs where the other data-dependent audits live.

Exit 0 = every readable page agrees. 2 = a finding. 3 = nothing could be checked at all.
"""
from __future__ import annotations

import argparse
import io
import json
import os
import re
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))

EXIT_CLEAN, EXIT_FINDING, EXIT_CANNOT_RUN = 0, 2, 3

# Unicode fractions the extractor folds to ASCII. Folded on BOTH sides, so "1½ cups" and "1 1/2 cups"
# compare equal rather than reading as a quantity that moved.
FRACTIONS = {
    "¼": "1/4", "½": "1/2", "¾": "3/4", "⅓": "1/3", "⅔": "2/3",
    "⅛": "1/8", "⅜": "3/8", "⅝": "5/8", "⅞": "7/8", "⅙": "1/6",
    "⅚": "5/6", "⅕": "1/5", "⅖": "2/5", "⅗": "3/5", "⅘": "4/5",
}
NUM = re.compile(r"\d+(?:\.\d+)?(?:\s*/\s*\d+)?")


def normalise(s: str) -> str:
    """The comparable form of an ingredient line, on either side.

    Folds unicode fractions, strips parentheticals, lowercases and collapses whitespace - the four
    things the extractor does on purpose. Everything else is left alone: a checker that normalised
    further would stop being able to see the drift it exists for.

    THE FRACTION MAP RUNS BEFORE NFKC, and the order is the bug this cost. NFKC turns "1half" into
    "1 1(fraction-slash)2" with no space, so a later map never sees the character and the line reads
    as 11/2 = 5.5 instead of 1.5 - which made the calibration case this file depends on report a
    quantity that had not moved.
    """
    s = str(s or "")
    for k, v in FRACTIONS.items():
        s = s.replace(k, " " + v + " ")
    s = unicodedata.normalize("NFKC", s)
    s = s.replace("⁄", "/")              # fraction slash, after NFKC has introduced any
    s = re.sub(r"(?<=\d)(?=\d+\s*/)", " ", s)   # "11/2" left by NFKC is "1 1/2"
    s = re.sub(r"\([^)]*\)", " ", s)          # the extractor strips these
    s = re.sub(r"[^a-z0-9/.\s-]", " ", s.lower())
    return re.sub(r"\s+", " ", s).strip()


def numbers(s: str):
    """Every quantity in a line, as floats, with `a/b` evaluated. This is the strict half."""
    out = []
    for m in NUM.finditer(normalise(s)):
        tok = m.group(0).replace(" ", "")
        try:
            if "/" in tok:
                a, b = tok.split("/", 1)
                out.append(round(float(a) / float(b), 4) if float(b) else 0.0)
            else:
                out.append(round(float(tok), 4))
        except Exception:                                          # noqa: BLE001
            continue
    return out


# THE UNITS THAT MOVE A PRICE. Compared as strictly as the numbers, because "1 cup" and "1 pound"
# carry the same number and are not the same money - the drift this file exists for. Singular and
# plural fold together; anything not on this list is prose and is compared loosely.
UNITS = {
    "cup": "cup", "cups": "cup", "c": "cup",
    "tbsp": "tbsp", "tablespoon": "tbsp", "tablespoons": "tbsp", "tbs": "tbsp",
    "tsp": "tsp", "teaspoon": "tsp", "teaspoons": "tsp",
    "oz": "oz", "ounce": "oz", "ounces": "oz",
    "lb": "lb", "lbs": "lb", "pound": "lb", "pounds": "lb",
    "g": "g", "gram": "g", "grams": "g",
    "kg": "kg", "kilogram": "kg", "kilograms": "kg",
    "ml": "ml", "milliliter": "ml", "milliliters": "ml",
    "l": "l", "liter": "l", "liters": "l", "litre": "l", "litres": "l",
    "quart": "qt", "quarts": "qt", "qt": "qt",
    "pint": "pt", "pints": "pt", "pt": "pt",
    "clove": "clove", "cloves": "clove",
    "can": "can", "cans": "can", "package": "pkg", "packages": "pkg", "pkg": "pkg",
    "slice": "slice", "slices": "slice", "stick": "stick", "sticks": "stick",
}


def units(s: str):
    """The measurement units in a line, folded to one spelling each. The other strict half."""
    return [UNITS[w] for w in normalise(s).split() if w in UNITS]


def prose(s: str) -> str:
    """The line with its numbers and units removed - WHAT it is, rather than how much.

    Pairing scores this and not the whole line, because the numbers and units are precisely what may
    have drifted: including them made "2 pounds chicken thighs" fail to pair with "1 pound chicken
    thighs" and come back as an invention plus a drop, instead of as the one line whose quantity
    moved.
    """
    keep = [w for w in normalise(s).split()
            if w not in UNITS and not re.fullmatch(r"[\d./-]+", w)]
    return " ".join(keep)


def overlap(a: str, b: str) -> float:
    """Token overlap of two lines, 0..1, over the SHORTER one.

    Over the shorter deliberately: the extractor drops words (a stripped parenthetical, a brand), so
    scoring over the longer would punish exactly the normalisation we accept.
    """
    ta, tb = set(normalise(a).split()), set(normalise(b).split())
    if not ta or not tb:
        return 0.0
    return len(ta & tb) / float(min(len(ta), len(tb)))


def match_lines(ours, theirs, floor=0.6):
    """Greedy best-overlap pairing. Returns (pairs, unmatched_ours, unmatched_theirs).

    Greedy rather than optimal on purpose: an ingredient list is short, the pairing is nearly always
    unambiguous, and a Hungarian solver here would be more code than the thing it decides.
    """
    left = list(range(len(theirs)))
    pairs, lost = [], []
    for i, o in enumerate(ours):
        best, bs = None, 0.0
        for j in left:
            s = overlap(prose(o), prose(theirs[j]))
            if s > bs:
                best, bs = j, s
        if best is not None and bs >= floor:
            pairs.append((i, best, bs))
            left.remove(best)
        else:
            lost.append(i)
    return pairs, lost, left


def judge(ours, theirs, floor=0.6):
    """Findings comparing our transcription against the page's own ingredient list.

    Three kinds, in the order they cost money:
      quantity-moved  a paired line whose NUMBERS differ - this reprices a live card
      invented        a line we have that the page does not
      dropped         a line the page has that we do not
    """
    findings = []
    pairs, lost_ours, lost_theirs = match_lines(ours, theirs, floor)
    for i, j, _s in pairs:
        no, nt = numbers(ours[i]), numbers(theirs[j])
        uo, ut = units(ours[i]), units(theirs[j])
        if no != nt:
            findings.append({"kind": "quantity-moved", "ours": ours[i], "theirs": theirs[j],
                             "why": "the numbers differ: %s vs %s" % (no, nt)})
        elif uo != ut:
            # THE UNIT IS AS PRICE-RELEVANT AS THE NUMBER. "1 cup" and "1 pound" agree on every digit.
            findings.append({"kind": "unit-moved", "ours": ours[i], "theirs": theirs[j],
                             "why": "same number, different unit: %s vs %s" % (uo or ["none"], ut or ["none"])})
    for i in lost_ours:
        findings.append({"kind": "invented", "ours": ours[i], "theirs": None,
                         "why": "no line on the page matches this one"})
    for j in lost_theirs:
        findings.append({"kind": "dropped", "ours": None, "theirs": theirs[j],
                         "why": "the page states this line and the transcription does not"})
    return findings


def page_ingredients(html: str):
    """The page's own recipeIngredient list from JSON-LD, or None when it states none.

    None is NOT an empty list. A page with no machine-readable recipe cannot be checked, and saying
    "0 ingredients, 0 findings" about it would be the cleanest-looking lie available.
    """
    if not html:
        return None
    for m in re.finditer(r'<script[^>]+application/ld\+json[^>]*>(.*?)</script>', html,
                         re.S | re.I):
        try:
            doc = json.loads(m.group(1).strip())
        except Exception:                                          # noqa: BLE001
            continue
        stack = [doc]
        while stack:
            node = stack.pop()
            if isinstance(node, list):
                stack.extend(node)
                continue
            if not isinstance(node, dict):
                continue
            for k in ("@graph", "mainEntity", "mainEntityOfPage"):
                if k in node:
                    stack.append(node[k])
            types = node.get("@type")
            types = types if isinstance(types, list) else [types]
            if any(str(x).lower() == "recipe" for x in types if x):
                ing = node.get("recipeIngredient") or node.get("ingredients")
                if isinstance(ing, list) and ing:
                    return [str(x) for x in ing]
    return None


def selftest():
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    print("audit_transcription_fidelity self-test")
    print("")

    # MUST FIRE - the drift that costs money, and the two that lose a line.
    f = judge(["1 cup smoked sausage"], ["1 pound smoked sausage"])
    T("MUST FIRE  THE ONE THAT COSTS MONEY - a UNIT swap keeps every digit identical and reprices the "
      "card, and it went invisible until this case existed",
      [x["kind"] for x in f] == ["unit-moved"], json.dumps(f)[:200])
    f2 = judge(["2 pounds chicken thighs"], ["1 pound chicken thighs"])
    T("MUST FIRE  a quantity that moved on a paired line is a finding - this reprices a live card",
      [x["kind"] for x in f2] == ["quantity-moved"], json.dumps(f2)[:200])
    f3 = judge(["1 cup rice", "2 tbsp soy sauce"], ["1 cup rice"])
    T("MUST FIRE  a line we have that the page does not is INVENTED",
      [x["kind"] for x in f3] == ["invented"], json.dumps(f3)[:200])
    f4 = judge(["1 cup rice"], ["1 cup rice", "2 tbsp soy sauce"])
    T("MUST FIRE  a line the page states and we do not is DROPPED",
      [x["kind"] for x in f4] == ["dropped"], json.dumps(f4)[:200])
    T("MUST FIRE  a page with no machine-readable recipe is UNCHECKABLE, not clean - '0 findings' "
      "about a page we could not read is the cleanest-looking lie available",
      page_ingredients("<html><body>a recipe, in prose</body></html>") is None, "read as empty")

    # MUST NOT FIRE - the normalisations the extractor makes ON PURPOSE. This is the calibration the
    # whole file lives or dies on. [[extractor-raw-is-not-verbatim]]
    T("MUST NOT FIRE  THE CALIBRATION - a unicode fraction and its ASCII form are the same quantity",
      judge(["1 1/2 cups milk"], ["1½ cups milk"]) == [],
      json.dumps(judge(["1 1/2 cups milk"], ["1½ cups milk"]))[:200])
    T("MUST NOT FIRE  a stripped parenthetical is a normalisation, not a dropped line",
      judge(["14 ounces smoked sausage"], ["14 ounces smoked sausage (about 1 package)"]) == [],
      json.dumps(judge(["14 ounces smoked sausage"], ["14 ounces smoked sausage (about 1 package)"]))[:200])
    T("MUST NOT FIRE  casing and punctuation do not move a quantity",
      judge(["1 Cup Rice, rinsed"], ["1 cup rice rinsed"]) == [],
      json.dumps(judge(["1 Cup Rice, rinsed"], ["1 cup rice rinsed"]))[:200])
    T("MUST NOT FIRE  a reordered list still pairs line for line",
      judge(["2 tbsp soy sauce", "1 cup rice"], ["1 cup rice", "2 tbsp soy sauce"]) == [],
      json.dumps(judge(["2 tbsp soy sauce", "1 cup rice"], ["1 cup rice", "2 tbsp soy sauce"]))[:200])

    # CLEAN TWIN - adjacent behaviour that still works.
    T("CLEAN TWIN JSON-LD inside an @graph is still found",
      page_ingredients('<script type="application/ld+json">{"@graph":[{"@type":"Recipe",'
                       '"recipeIngredient":["1 cup rice"]}]}</script>') == ["1 cup rice"],
      str(page_ingredients('<script type="application/ld+json">{"@graph":[{"@type":"Recipe",'
                           '"recipeIngredient":["1 cup rice"]}]}</script>')))
    T("CLEAN TWIN a Recipe node in a bare list is found too",
      page_ingredients('<script type="application/ld+json">[{"@type":"Article"},{"@type":"Recipe",'
                       '"recipeIngredient":["2 eggs"]}]</script>') == ["2 eggs"], "missed a list form")
    T("CLEAN TWIN a fraction slash character reads as a fraction",
      numbers("1⁄2 cup") == [0.5], str(numbers("1⁄2 cup")))
    T("CLEAN TWIN overlap is scored over the SHORTER line, so a stripped brand does not read as a miss",
      overlap("1 cup rice", "1 cup organic long grain rice") == 1.0,
      str(overlap("1 cup rice", "1 cup organic long grain rice")))
    T("CLEAN TWIN two empty lists agree and produce nothing", judge([], []) == [], "invented a finding")

    if bad:
        print("")
        print("SELF-TEST FAIL: %d check(s)" % len(bad))
        print("TRANSCRIPTION-FIDELITY-SELFTEST-COMPLETE")
        return 1
    print("")
    print("SELF-TEST PASS: 5 must-fire cases led by the UNIT swap that keeps every digit identical, "
          "4 must-not-fire cases pinning the normalisations the extractor makes on purpose, and 5 "
          "clean twins")
    print("TRANSCRIPTION-FIDELITY-SELFTEST-COMPLETE")
    return 0


def fetch(url, timeout=25):
    """The page, or None. Any failure is None - which this file reports as CANNOT-CHECK, never clean."""
    import urllib.request                                          # noqa: PLC0415
    req = urllib.request.Request(url, headers={
        "User-Agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                       "(KHTML, like Gecko) Chrome/126.0 Safari/537.36")})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:    # noqa: S310
            return r.read().decode("utf-8", errors="replace")
    except Exception:                                              # noqa: BLE001
        return None


def main() -> int:
    ap = argparse.ArgumentParser(description="does the transcription match the page it came from")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--run", default="", help="a hunt run dir; checks every file in extracted/")
    ap.add_argument("--file", default="", help="one extracted transcription")
    ap.add_argument("--limit", type=int, default=0, help="stop after N pages")
    a = ap.parse_args()
    if a.selftest:
        return selftest()

    paths = []
    if a.file:
        paths = [a.file]
    elif a.run:
        d = os.path.join(a.run, "extracted")
        if os.path.isdir(d):
            paths = [os.path.join(d, f) for f in sorted(os.listdir(d)) if f.endswith(".json")]
    if not paths:
        print("TRANSCRIPTION FIDELITY BLIND: no transcriptions named. Pass --run <run-dir> or --file.")
        print("TRANSCRIPTION-FIDELITY-COMPLETE blind=no-input")
        return EXIT_CANNOT_RUN
    if a.limit:
        paths = paths[:a.limit]

    checked, unreadable, findings = 0, [], []
    for p in paths:
        try:
            with io.open(p, encoding="utf-8-sig") as f:
                doc = json.load(f)
        except Exception as e:                                     # noqa: BLE001
            unreadable.append((os.path.basename(p), "the transcription did not parse (%s)" % e))
            continue
        url = doc.get("source_url") or ""
        ours = [str(i.get("raw") or "") for i in (doc.get("ingredients") or []) if isinstance(i, dict)]
        if not url or not ours:
            unreadable.append((os.path.basename(p), "no source_url or no ingredient lines"))
            continue
        theirs = page_ingredients(fetch(url))
        if theirs is None:
            unreadable.append((os.path.basename(p), "the page states no machine-readable recipe"))
            continue
        checked += 1
        for f_ in judge(ours, theirs):
            f_["slug"] = os.path.basename(p)
            findings.append(f_)

    for name, why in unreadable:
        print("  CANNOT CHECK  %-52s %s" % (name[:52], why))
    for f_ in findings:
        print("  %-14s %-52s %s" % (f_["kind"].upper(), f_["slug"][:52], f_["why"]))

    print("")
    print("  %d of %d transcription(s) were checked against their page; %d could not be."
          % (checked, len(paths), len(unreadable)))
    if not checked:
        print("TRANSCRIPTION FIDELITY BLIND: not one page could be read, so nothing was proven. That is "
              "NOT the same as agreement, and it must not be recorded as a pass.")
        print("TRANSCRIPTION-FIDELITY-COMPLETE blind=nothing-readable checked=0 of %d" % len(paths))
        return EXIT_CANNOT_RUN
    if findings:
        print("TRANSCRIPTION FIDELITY AUDIT FAILED: %d finding(s) across %d checked page(s). A "
              "transcription that drifted from its page passes recipe-source-qa, which compares the "
              "BUILT card against the transcription - one link downstream of here - so the card "
              "faithfully reproduces the wrong thing." % (len(findings), checked))
        print("TRANSCRIPTION-FIDELITY-COMPLETE checked=%d findings=%d unreadable=%d"
              % (checked, len(findings), len(unreadable)))
        return EXIT_FINDING
    print("transcription-fidelity: PASSED - %d checked page(s) state the ingredient lines we "
          "transcribed, quantities included. %d page(s) could not be read and are NOT counted as "
          "agreement." % (checked, len(unreadable)))
    print("TRANSCRIPTION-FIDELITY-COMPLETE checked=%d findings=0 unreadable=%d" % (checked, len(unreadable)))
    return EXIT_CLEAN


if __name__ == "__main__":
    sys.exit(main())
