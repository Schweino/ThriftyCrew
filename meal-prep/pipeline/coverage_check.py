"""Ingredient-coverage check: set arithmetic, no model, no opinion.

    python meal-prep/pipeline/coverage_check.py --spec built.json --source transcription.json

recipe-source-qa's first and heaviest check is stated in its own definition as
a set operation: "one in the spec but not in the source is INVENTED; one in the
source but not the spec is DROPPED". That is arithmetic. Asking a language
model to perform it costs a call, takes seconds, and is LESS reliable than the
three lines of code that do it exactly — a model can miscount a fourteen-item
list; a set cannot.

So this runs first and settles what is settleable. What it CANNOT settle it
says so about, loudly, and hands on:

  * whether a substitution was deliberate and defensible
  * whether the METHOD still cooks the source's dish
  * whether prose numbers, title and credit drifted

Those are judgement and stay with the reviewer. The saving is not that a model
is replaced — it is that the reviewer is handed an answered question instead of
a list to count.

MATCHING IS DELIBERATELY CONSERVATIVE. A missed pairing here reports a false
DROP, which costs a human ten seconds; a wrong pairing hides a real invention,
which is how a recipe nobody found gets sold. Normalise, singularise, ignore
preparation words — then require the food words to actually correspond.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import re
import sys
import unicodedata

# Words that describe PREPARATION or PACKAGING, never the food itself. Stripped
# before comparison so "chicken thighs, boneless" and "boneless chicken thighs"
# are recognised as one ingredient rather than two.
NOISE = {
    "fresh", "frozen", "chopped", "diced", "minced", "sliced", "shredded",
    "grated", "crushed", "ground", "drained", "rinsed", "divided", "melted",
    "softened", "packed", "large", "medium", "small", "boneless", "skinless",
    "optional", "taste", "serving", "garnish", "cut", "into", "pieces", "cubes",
    "thinly", "finely", "roughly", "peeled", "seeded", "trimmed", "cooked",
    "uncooked", "raw", "low", "sodium", "reduced", "fat", "free", "whole",
    "extra", "virgin", "kosher", "sea", "table", "granulated", "packed", "plus",
    "more", "needed", "room", "temperature", "warm", "cold", "hot", "canned",
    "jarred", "bottled", "container", "package", "can", "jar", "box", "bag",
    "and", "or", "the", "of", "for", "with", "a", "an", "to", "in", "on",
}


def _words(text: str) -> list[str]:
    """Significant words IN ORDER — order matters because the last one is the
    head noun (see _head).

    A PARENTHETICAL IS A NOTE ABOUT THE FOOD, NOT THE FOOD, and dropping it is
    what keeps the head noun honest. Measured 2026-08-23 against the published
    lowcarb-100 waves: "Sun-Dried Tomatoes (Oil-Packed)" ended in the word
    "oil", so its head noun was oil, and it could not pair with the source's
    "sun-dried tomatoes", so the check reported the tomatoes both INVENTED and
    DROPPED at once, on a recipe that is correct. The form question the
    parenthetical raises is real and it stays with the QA agent, which is
    already what not_checked says.
    """
    s = unicodedata.normalize("NFKD", str(text or ""))
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = re.sub(r"\([^)]*\)", " ", s)
    s = re.sub(r"[^a-z ]+", " ", s.lower())
    out = []
    for w in s.split():
        if w in NOISE or len(w) < 3:
            continue
        # crude singularisation: enough for food words, and both sides get it
        if len(w) > 3 and w.endswith("es") and not w.endswith("ses"):
            w = w[:-2]
        elif len(w) > 3 and w.endswith("s"):
            w = w[:-1]
        if w not in out:
            out.append(w)
    return out


def _key(text: str) -> tuple[set[str], str | None]:
    ws = _words(text)
    return set(ws), _head(ws)


def _head(words: list[str]) -> str | None:
    """The HEAD NOUN — the last surviving word, which is what the food IS.
    'boneless chicken thighs' -> thigh. 'chicken broth' -> broth."""
    return words[-1] if words else None


def _compound_head(a, b) -> bool:
    """One spelling, two words: 'Panko Breadcrumbs' against 'panko bread crumbs'.

    The head nouns are 'breadcrumb' and 'crumb' and nothing else in the pair
    disagrees, so the head-noun rule reported the same food both INVENTED and
    DROPPED. Accepted only when one side's head IS the other side's last two
    words run together and the modifier sets do not conflict, which is narrow
    enough that it cannot reach a real substitution: 'chicken stock' and
    'chicken broth' are not a compound of each other, and neither are
    'chicken thighs' and 'chicken breast'.
    """
    aw, ah = a
    bw, bh = b

    def glued(words, head):
        # _key hands back a SET, so there is no "last" word to take - every modifier is tried against
        # the head instead. That is still narrow: it only ever produces a word the other side already
        # spelled as two.
        return set(w + head for w in words if w != head)

    return (ah in glued(bw, bh)) or (bh in glued(aw, ah))


def _pairs(a: tuple[set[str], str | None], b: tuple[set[str], str | None]) -> bool:
    """Do two ingredient names denote the same food?

    THE HEAD NOUN MUST MATCH, and overlap alone is not enough. An earlier
    version required only that shared words cover half the shorter name, and
    its own docstring claimed that stopped 'chicken thighs' pairing with
    'chicken broth' — it did not: two-word names sharing one word score exactly
    0.5 and passed. That would have silently paired 'chicken thighs' with
    'chicken breast' too, hiding precisely the cut substitution this check
    exists to catch, and hiding it as a PASS.

    Head-noun agreement is the honest test of "same food": thigh/breast,
    broth/stock and cream/milk all separate, while 'extra virgin olive oil' and
    'olive oil' still meet at 'oil' — and the modifier check below keeps THOSE
    apart when the modifiers actually disagree.
    """
    aw, ah = a
    bw, bh = b
    if not aw or not bw or not ah or not bh:
        return False
    if ah != bh and not _compound_head(a, b):
        return False
    # Same head, different modifiers ('red onion' vs 'green onion', 'heavy
    # cream' vs 'sour cream'): only pair when the modifier sets do not conflict.
    amod, bmod = aw - {ah}, bw - {bh}
    if amod and bmod and not (amod & bmod):
        return False
    return True


def _names(doc) -> list[str]:
    r"""Pull ingredient names out of any of the shapes this pipeline carries: a
    transcription (raw/item), an intake (ingredients[]), or a v2 BUILT spec.

    THE BUILT SPEC WAS THE MISSING ONE, and it is the shape the QA lane actually
    passes. recipe-source-qa's own instruction is
    `--spec <built.json> --source <transcription.json>`, the orchestrator hands
    it meal-prep\db\recipes\<slug>.json, and that file has no `ingredients`
    key at all - its lines live in `scaler.ing` (canon + item), with
    `ingredients_grams` and `ingredients_display` as the other two copies. This
    function looked for `ingredients`, found nothing, and reported ZERO spec
    ingredients, which turns every source line into a false DROPPED. Measured
    2026-08-23 against keto-cheeseburger-skillet: 0 matched, 12 dropped, on a
    recipe whose twelve lines all pair. Found while building the v3 QA battery
    on top of this function (PLAN-recipe-hunter-v3 D2).

    The order is deliberate. `scaler.ing` is the layer that carries the CANON
    name - the one the cost engine and the vocabulary agree on - and a display
    rename ("glass noodles") must not be read as a different food.
    """
    if isinstance(doc, dict):
        rows = (doc.get("ingredients") or doc.get("extraction", {}).get("ingredients")
                or ((doc.get("scaler") or {}).get("ing"))
                or doc.get("ingredients_grams")
                or doc.get("items") or [])
    else:
        rows = doc or []
    out = []
    for r in rows:
        if isinstance(r, str):
            out.append(r)
        elif isinstance(r, dict):
            out.append(r.get("canon") or r.get("item") or r.get("ingredient")
                       or r.get("name") or r.get("raw") or "")
    return [o for o in out if o]


_RX_AND = re.compile(r"(?i)\s*(?:,\s*)?\band\b\s*")
_RX_OR = re.compile(r"(?i)\s*\bor\b\s*")


def _requirements(source_names: list[str]) -> list[dict]:
    """One source LINE can state more than one food, and reading it as one name
    is what produced most of this check's false alarms on real recipes.

    Measured 2026-08-23 over the 20 published lowcarb-100 recipes: 88 coverage
    findings, and the largest single class was "salt and pepper": one source
    line against the spec's two lines, reported as one DROP plus two
    INVENTIONS on eight different recipes that are all correct.

    Two readings, and they pull in opposite directions on purpose:

      AND is a CONJUNCTION and splitting it makes this check STRICTER. "salt
      and pepper" becomes two separate requirements, so a spec that carries
      salt and forgot the pepper now fails where before the single line was
      satisfied by either one.

      OR is a CHOICE the source itself offered. "ground beef or ground turkey"
      and "water or chicken broth" are the page telling the cook to pick; a
      spec that picked one has invented nothing, so any alternative satisfies
      the requirement. This is the one loosening here, and it is the source's
      own permission, not ours.

    A split is only taken when BOTH sides survive to a real head noun, so
    "salt and pepper to taste" splits and "black and white sesame" does not
    lose its meaning to a fragment that denotes nothing.
    """
    reqs = []
    for line in source_names:
        parts = [pp for pp in _RX_AND.split(line) if pp and pp.strip()]
        if len(parts) < 2 or not all(_head(_words(pp)) for pp in parts):
            parts = [line]
        for part in parts:
            alts = [a for a in _RX_OR.split(part) if a and a.strip()]
            if len(alts) < 2 or not all(_head(_words(a)) for a in alts):
                alts = [part]
            reqs.append({"line": line, "text": part, "alts": alts,
                         "keys": [_key(a) for a in alts]})
    return reqs


# ---------------------------------------------------------------------------------------------------
# A COMPOSITE TERM CAN NEVER HAVE A ROW OF ITS OWN, and until 2026-08-26 nothing said so upstream.
#
# WHAT IT COST. On run hunt-2026-08-26-ten, "Salt and Pepper" reached the write lane as one food and
# took apple-spice-pork-chops and honey-balsamic-chicken-tenders STUCK with it - the food DB cannot
# carry a row for two foods, so the intake skeleton refused to complete and the band could not be
# ruled. The same defect PARKED four more recipes one lane earlier, where "Garlic Powder, Cumin, and
# Chili Powder" and "Dried Thyme, Dried Basil and Onion Powder" waited on a commodity id no single
# id can be. The mapper wrote "two pantry foods on one unsplittable line" and it was right about the
# line and wrong about splittable: its own `buy` string already read "1/2 tsp salt and 1/2 tsp black
# pepper", which is two measurements of two foods.
#
# WHY IT LIVES HERE. `_requirements` below already splits a SOURCE line on AND, and has since
# 2026-08-23. The rule is the same rule; what differs is the cost of being wrong. Down in the
# coverage check a bad split only makes the check STRICTER and a person reads the finding. Up at term
# formation a bad split creates a second shopping line and a second priced ingredient, so this road
# is deliberately narrower than that one and every extra guard is named below.
#
# NOT A FORK OF THE SCORING. _words/_head are imported from the same functions the coverage check
# scores with, because a second head-noun implementation in PowerShell is the forked-taxonomy defect
# this estate already has scars from.

# Fixed culinary compounds: ONE food whose name happens to contain "and", where BOTH halves are also
# heads the estate knows, so the head-noun guard below cannot separate them. Kept short on purpose -
# it is the exception list, not the mechanism. Matched as a substring of the lowercased term.
COMPOSITE_KEEP_WHOLE = (
    "macaroni and cheese", "mac and cheese", "sweet and sour", "half and half",
    "bread and butter", "biscuits and gravy", "chicken and rice", "rice and beans",
    "beans and rice", "pork and beans", "franks and beans", "ham and cheese",
    "beef and broccoli", "corned beef and cabbage", "chips and salsa", "cookies and cream",
    "peaches and cream", "surf and turf", "bangers and mash", "hot and sour",
    "salt and vinegar", "oil and vinegar", "black and white", "sweet and spicy",
    "chicken and dumplings", "shrimp and grits", "spaghetti and meatballs",
)

# A separator list, not a sentence parser: "a, b, and c" and "a and b" are the two shapes real
# ingredient lines use. The comma road runs first so "a, b, and c" yields three parts, not two.
_RX_ENUM = re.compile(r"(?i)\s*,\s*(?:and\s+)?|\s+and\s+")

# FOUR IS AN ENUMERATION; FIVE IS A SECTION HEADING. "Optional Garnishes: sour cream, cilantro,
# lime, jalapeno, cheese" is not an ingredient line and must not become five of them.
COMPOSITE_MAX_PARTS = 4

# ...AND A FOUR-PART HEADING SLIPS STRAIGHT UNDER THAT CAP, which is the thing the count guard above
# could not see about its own example. Measured 2026-08-26 on easy-beef-enchiladas: the extractor read
# the heading "Optional Toppings: Diced Onion, Cilantro, Sour Cream, Shredded Lettuce" as an
# ingredient term. Four parts, so the cap passes it; onion, cilantro, cream and lettuce are all heads
# the estate knows, so the head guard passes it; and _words strips the colon, so the first part comes
# out as "Optional Toppings: Diced Onion" with the head noun 'onion' and nothing left to catch it.
# That is a term no food DB can carry a row for and no commodity id can price.
#
# THE LABEL IS NOT THE FOOD, AND THE FOODS AFTER IT ARE REAL. "For the sauce: soy sauce, honey,
# garlic" names three ingredients under a heading, so REFUSING the line would drop three real
# ingredients and DROPPED is what the coverage check would then call them. Stripping the label keeps
# every one of them and removes only the thing that was never a food. The parts still face every
# guard below, unchanged.
#
# TWO CLAUSES, AND THE SECOND IS THE ONE DOING THE WORK. What follows the colon must ENUMERATE: "Salt
# and pepper: to taste" is a phrase with a note, not a heading over a list, so there is no label to
# strip and the ordinary road rules it exactly as before. The label itself is held to a short phrase
# carrying no separator of its own, which is narrowing rather than a guard with a case behind it -
# said plainly here because this function's own header promises every extra guard is named.
_RX_LABEL = re.compile(r"^([^:,]{1,40}):\s+(?=\S)")


def known_heads(*name_lists) -> set:
    r"""The set of head nouns the estate already uses, from any lists of item names.

    This is the guard that does the real work, and it is checkable against live data: measured over
    db\ingredients.json plus food-macros-db.json on 2026-08-26 it holds 179 heads, and 'sweet',
    'macaroni', 'gravy' and 'turf' are all absent from it while 'pepper', 'cumin', 'basil' and
    'powder' are all present. That is exactly the line between "Sweet and Sour Sauce" (one food) and
    "Salt and Pepper" (two).
    """
    out = set()
    for names in name_lists:
        for n in (names or []):
            h = _head(_words(n))
            if h:
                out.add(h)
    return out


def split_composite(term: str, heads: set, resolved_whole: bool = False) -> list:
    """The parts a composite term names, or [] when it is one food.

    `resolved_whole` is the FIRST guard and the cheapest: a term the estate already resolves as a
    whole IS a food it carries, so it is never split however its name reads. "Half and Half" and
    "Old Bay Seasoning" never reach the rest of this function.
    """
    t = " ".join(str(term or "").split())
    if not t or resolved_whole:
        return []
    low = t.lower()
    if any(k in low for k in COMPOSITE_KEEP_WHOLE):
        return []
    # BEFORE THE ENUMERATION IS READ, NEVER AFTER. Leaving the label on makes the first part a phrase
    # like "Optional Toppings: Diced Onion", and every guard below then sees a known head noun.
    m = _RX_LABEL.match(t)
    if m:
        rest = t[m.end():].strip()
        if len(_RX_ENUM.split(rest)) > 1:
            t = rest
    parts = [p.strip(" ,") for p in _RX_ENUM.split(t)]
    parts = [p for p in parts if p]
    if len(parts) < 2 or len(parts) > COMPOSITE_MAX_PARTS:
        return []
    # EVERY part has to be a food this estate would recognise the SHAPE of. A part whose head noun
    # appears nowhere in the vocabulary or the food DB is a fragment, not an ingredient - which is
    # what stops "Sweet and Sour Sauce" becoming "Sweet" plus "Sour Sauce".
    for p in parts:
        h = _head(_words(p))
        if not h or h not in heads:
            return []
    # Two parts that denote the SAME food are one food said twice ("salt and salt"), and splitting
    # them would put the same ingredient on the card twice - the duplicate-line defect the skeleton
    # builder's own merge exists to prevent.
    keys = [_key(p) for p in parts]
    for i in range(len(keys)):
        for j in range(i + 1, len(keys)):
            if _pairs(keys[i], keys[j]):
                return []
    return parts


def _strip_bom(text: str) -> str:
    """PowerShell's pipe into a native exe writes a UTF-8 BOM ahead of the payload, and json.loads
    calls that "Unexpected UTF-8 BOM". Measured 2026-08-26 by map-preresolve's own fixture, which is
    the only caller of --split-terms and is a PowerShell one."""
    return (text or "").lstrip("﻿ \t\r\n") or "{}"


def coverage(spec_doc, source_doc) -> dict:
    spec, source = _names(spec_doc), _names(source_doc)
    spec_w = [(n, _key(n)) for n in spec]
    reqs = _requirements(source)

    matched_src = set()
    invented = []
    for name, w in spec_w:
        hit = next((i for i, r in enumerate(reqs)
                    if i not in matched_src and any(_pairs(w, k) for k in r["keys"])), None)
        if hit is None:
            invented.append(name)
        else:
            matched_src.add(hit)
    dropped, consolidated = [], []
    for i, r in enumerate(reqs):
        if i in matched_src:
            continue
        label = r["text"] if r["text"] == r["line"] else "%s (from %r)" % (r["text"], r["line"])
        # A SECTIONED RECIPE LISTS THE SAME FOOD TWICE - once under "for the meatballs" and again under
        # "for the sauce" - and the spec carries ONE line for it. Measured 2026-08-23: the source for
        # turkey-meatballs-cream-sauce-skillet lists garlic powder, Worcestershire and dried oregano
        # twice each, and flank-steak lists olive oil, red wine vinegar and parmesan twice. Calling
        # those DROPPED says "the built recipe has nothing that denotes it", which is simply false when
        # a spec line does denote it - and a check that states a falsehood is worse than a quiet one.
        # It is not waved through either: consolidating two lines raises a QUANTITY question, and that
        # question is the note.
        if any(any(_pairs(w, k) for k in r["keys"]) for _, w in spec_w):
            consolidated.append(label)
        else:
            dropped.append(label)
    src_w = reqs
    source = [r["text"] for r in reqs]

    findings = []
    for n in invented:
        findings.append({"check": "ingredient-coverage", "severity": "fail",
                         "detail": f"INVENTED: {n!r} is in the built recipe but "
                                   f"nothing in the source transcription denotes it"})
    for n in dropped:
        findings.append({"check": "ingredient-coverage", "severity": "fail",
                         "detail": f"DROPPED: the source lists {n!r} and the built "
                                   f"recipe has nothing that denotes it"})
    for n in consolidated:
        findings.append({"check": "ingredient-coverage", "severity": "note",
                         "detail": f"CONSOLIDATED: the source states {n!r} in more than one place and "
                                   f"the spec carries a single line for it - the food is present, so "
                                   f"the open question is whether that line's amount is the SUM"})
    return {
        "spec_ingredients": len(spec), "source_ingredients": len(source),
        "matched": len(matched_src), "invented": invented, "dropped": dropped,
        "consolidated": consolidated,
        # A note is not a failure. Only an invention or a real drop can fail this check; a consolidated
        # duplicate is a question for the reviewer, and severity is what says which is which.
        "verdict": "pass" if not [f for f in findings if f["severity"] == "fail"] else "fail",
        "findings": findings,
        # Said plainly so nobody mistakes a green light here for a full QA pass.
        "not_checked": ["method / technique drift", "deliberate substitutions",
                        "scaling arithmetic", "title", "credit", "prose numbers"],
    }


# ---------------------------------------------------------------------------------------------------
# THE QA BATTERY (PLAN-recipe-hunter-v3 S7 / D2, 2026-08-23)
#
# Coverage above answers ONE of source-QA's questions. The rest of its "heaviest check is already code"
# argument runs here: scaling arithmetic, prose numbers, title/credit/URL, the dash sweep and the
# servings claim are all things a set or a regex settles better than a model, and every one of them was
# still being done by hand inside a Fable context window. What is left for the agent afterwards is the
# residue it is actually for: was a substitution deliberate and defensible, does the METHOD still cook
# the source's dish, is this the same dish at all.
#
# THE BATTERY NEVER RULES ON THE RECIPE. It reports; recipe-source-qa issues the verdict, and it may
# re-derive anything here it distrusts. A battery FAIL is "the agent must look at this", not "reject".
#
# EXIT CODES (PLAN v3 section 4.5): 0 clean, 1 findings (the report is still written), 2 could-not-run.
# Exit 2 is a blocked stage, never a pass.
# ---------------------------------------------------------------------------------------------------

import datetime
import os
from fractions import Fraction

BATTERY_VERSION = 1

# ---- quantity grammar ------------------------------------------------------------------------------
# DELIBERATELY SMALL. meal-prep\pipeline\parse-compute.ps1 owns the real grammar - 597 lines of unit
# priority, container rules and density lookups - and re-deriving it here is exactly the mistake this
# estate keeps paying for. This reads only a LEADING amount, and when it cannot, it says so and the line
# is reported UNRATED rather than guessed. An unrated line is visible in the report; a guessed one is a
# wrong finding or, worse, a wrong pass.

_VULGAR = {'¼': Fraction(1, 4), '½': Fraction(1, 2), '¾': Fraction(3, 4),
           '⅓': Fraction(1, 3), '⅔': Fraction(2, 3), '⅛': Fraction(1, 8),
           '⅜': Fraction(3, 8), '⅝': Fraction(5, 8), '⅞': Fraction(7, 8)}

# base unit per family. Volume is counted in teaspoons and weight in grams because those are the units
# the estate's own densities file already thinks in.
_VOLUME = {'tsp': 1.0, 'teaspoon': 1.0, 'tbsp': 3.0, 'tbs': 3.0, 'tablespoon': 3.0,
           'floz': 6.0, 'fluidounce': 6.0, 'cup': 48.0, 'pint': 96.0, 'quart': 192.0,
           'gallon': 768.0, 'ml': 0.2028841, 'milliliter': 0.2028841, 'l': 202.8841, 'liter': 202.8841,
           'litre': 202.8841}
_WEIGHT = {'g': 1.0, 'gram': 1.0, 'oz': 28.349523, 'ounce': 28.349523,
           'lb': 453.59237, 'pound': 453.59237, 'kg': 1000.0, 'kilogram': 1000.0}

# THE HOUSE QUARTER. The mapper's own stated convention is "quantities quantized to house quarters" - a
# cook measure is rounded to the nearest 1/4 of its unit, because there is no eighth-teaspoon in the
# drawer. Rounding to the nearest quarter moves a number by at most an eighth of a unit, so a line whose
# whole deviation from the exact scale is within an eighth of its own unit is EXPLAINED by that rounding
# and is not a hand adjustment. This matters most on small measures: 1/4 tsp x 3.5 = 0.875 tsp, which
# quantizes to 1 tsp - a 14% deviation that is the house convention working correctly, not a defect.
QUARTER_STEP = 0.25
QUANT_SLACK = QUARTER_STEP / 2.0

# PLAN v3 section 4.5 thresholds for the scale-ratio check.
RATIO_FAIL_PCT = 0.10
RATIO_NOTE_PCT = 0.05


def _norm_unit(u: str) -> str:
    u = re.sub(r'[^a-z]', '', (u or '').lower())
    if u.endswith('es') and u[:-2] in ('ounc', 'inch'):
        u = u[:-2]
    elif u.endswith('s') and len(u) > 1 and not u.endswith('ss'):
        u = u[:-1]
    return u


# A LADDER, not one regex, and that is the whole lesson of this function. The single-pattern version
# read '1/2 cup' as ONE cup: a greedy leading-integer group swallowed the numerator, the fraction branch
# then had only '/2' left to match, and the unit group could not start on a slash - so the amount came
# back as (1.0, '') with no unit, which made every half-cup line UNRATED and quietly shrank the ratio
# check to the lines that happened to use whole numbers. It passed the clean twin. Only the MUST FIRE
# beside it noticed, which is the argument for shipping both. Each rung is tried in order, longest form
# first, and the first one that matches wins.
_RX_MIXED = re.compile(r'^\s*(\d+)[\s-]+(\d+)\s*[/\u2044]\s*(\d+)')      # 3 1/2   |  1-1/2
_RX_FRAC = re.compile(r'^\s*(\d+)\s*[/\u2044]\s*(\d+)')                   # 1/2
_RX_VULG_MIX = re.compile(r'^\s*(\d+)?\s*([\u00bc\u00bd\u00be\u2153\u2154\u215b\u215c\u215d\u215e])')  # 1 1/2 as one glyph
_RX_DEC = re.compile(r'^\s*(\d+(?:\.\d+)?|\.\d+)')                        # 3  |  3.5  |  .75
_RX_UNIT = re.compile(r'^\s*([A-Za-z][A-Za-z.]*)')


def parse_amount(text):
    """Leading amount of a measure string -> (value, normalised unit) or None.

    '3 1/2 lb (80/20)' -> (3.5, 'lb');  '1/2 cup' -> (0.5, 'cup');
    '14 slices, chopped' -> (14.0, 'slice');  '7 tbsp (a bit under 1/2 cup)' -> (7.0, 'tbsp');
    'to taste' -> None.
    Only the LEADING amount, and only when a number actually starts the string: a line with no leading
    number has no single amount to scale, which is a refusal, not a zero.
    """
    s = str(text or '')
    if not s.strip():
        return None
    val = None
    rest = ''
    m = _RX_MIXED.match(s)
    if m and float(m.group(3)) != 0:
        val = float(m.group(1)) + float(m.group(2)) / float(m.group(3))
        rest = s[m.end():]
    if val is None:
        m = _RX_FRAC.match(s)
        if m and float(m.group(2)) != 0:
            val = float(m.group(1)) / float(m.group(2))
            rest = s[m.end():]
    if val is None:
        m = _RX_VULG_MIX.match(s)
        if m:
            val = float(m.group(1) or 0) + float(_VULGAR[m.group(2)])
            rest = s[m.end():]
    if val is None:
        m = _RX_DEC.match(s)
        if m:
            val = float(m.group(1))
            rest = s[m.end():]
    if val is None:
        return None
    # A vulgar fraction can also FOLLOW a whole number written plainly ('1 \u00bd cup').
    mv = _RX_VULG_MIX.match(rest)
    if mv and mv.group(1) is None:
        val += float(_VULGAR[mv.group(2)])
        rest = rest[mv.end():]
    mu = _RX_UNIT.match(rest)
    unit = _norm_unit(mu.group(1)) if mu else ''
    return (val, unit)


# THE MASS A LINE STATES ABOUT ITSELF, ANYWHERE IN IT (2026-08-27).
#
# THIS IS NOT parse_amount AND MUST NOT BECOME IT. parse_amount answers "what is the LEADING amount",
# deliberately - its own fixture pins "1 3/4 cups chopped (about 2 medium)" to 1.75 cup, and the
# scale-ratio check depends on that reading. This answers a different question, which some lines need
# because they state BOTH a count and a weight:
#
#     "2 medium 1.5 lbs. chicken breasts"
#      parse_amount        -> (2.0, "medium")   the count, per its contract
#      stated_mass_grams   -> 680.4 g           the 1.5 lbs, which is the fact
#
# WHY IT MATTERS, TWICE. The quantity engine read that line as 2 x 200 g = 400 g and vetoed the
# mapper's correct 680 g, sticking honey-balsamic-chicken-tenders three times in one run (fixed
# 2026-08-27 in map-preresolve.ps1). The SAME line then defeated band_precheck.py, which read
# "2 medium", missed the protein entirely and computed 152 cal against a true 349. One ambiguity,
# two lanes, two languages.
#
# ITS POWERSHELL TWIN IS Get-StatedMassGrams IN map-preresolve.ps1 and the two must agree: same
# units, same conservative refusals, first mass token only. Each file's self-test names the other so
# a change to one is a visible question about the other - this estate has been bitten by the same
# rule implemented twice and left to drift (notes-vs-bid, two diverged copies firing on disjoint
# words), and naming the twin is the cheapest defence there is.
_MASS_G = {'g': 1.0, 'gram': 1.0, 'grams': 1.0, 'kg': 1000.0, 'kilogram': 1000.0,
           'kilograms': 1000.0, 'oz': 28.349523125, 'ounce': 28.349523125,
           'ounces': 28.349523125, 'lb': 453.59237, 'lbs': 453.59237,
           'pound': 453.59237, 'pounds': 453.59237}
_RX_MASS = re.compile(
    r'(?P<n>\d+(?:\.\d+)?(?:\s*/\s*\d+)?)[\s-]*'
    r'(?P<u>lbs?\.?|pounds?|ozs?\.?|ounces?|kgs?|kilograms?|grams?|g)\b', re.I)


def stated_mass_grams(text):
    """The first explicit MASS this line states, in grams, or None when it states none.

    DELIBERATELY CONSERVATIVE, exactly like its PowerShell twin: first token only, no ranges, no
    addition, no "plus more for serving". Anything it cannot read confidently is None - it exists to
    correct a number, and a wrong correction is worse than the count it replaces.
    """
    t = str(text or '')
    if not t.strip():
        return None
    m = _RX_MASS.search(t)
    if not m:
        return None
    n = m.group('n')
    u = m.group('u').replace('.', '').lower()
    if '/' in n:
        a, _, b = n.partition('/')
        try:
            a, b = float(a.strip()), float(b.strip())
        except ValueError:
            return None
        if b == 0:
            return None
        val = a / b
    else:
        try:
            val = float(n)
        except ValueError:
            return None
    if val <= 0:
        return None
    g = _MASS_G.get(u)
    return val * g if g else None


def to_base(value, unit):
    """(value, unit) -> (base value, family). Volume in tsp, weight in grams, anything else counted in
    its own noun so 'slice' can only ever be compared with 'slice'."""
    if unit in _VOLUME:
        return (value * _VOLUME[unit], 'volume')
    if unit in _WEIGHT:
        return (value * _WEIGHT[unit], 'weight')
    return (value, 'count:' + (unit or ''))


def _unit_factor(unit):
    if unit in _VOLUME:
        return _VOLUME[unit]
    if unit in _WEIGHT:
        return _WEIGHT[unit]
    return 1.0


def _median(xs):
    xs = sorted(xs)
    n = len(xs)
    if not n:
        return None
    if n % 2:
        return xs[n // 2]
    return (xs[n // 2 - 1] + xs[n // 2]) / 2.0


# ---- row extraction --------------------------------------------------------------------------------

def _spec_rows(spec) -> list:
    """Spec ingredient rows with the two things the ratio check needs: the canonical name and the COOK
    MEASURE the reader is told to use. The mapper derives grams FROM that printed measure via
    densities.json, so the two agree by construction and a ratio taken on the measure is the same ratio
    grams would give - without this file needing a density table of its own."""
    out = []
    scaler = (spec or {}).get('scaler') or {}
    for r in (scaler.get('ing') or []):
        out.append({'name': r.get('canon') or r.get('item') or '', 'buy': r.get('buy') or '',
                    'grams': r.get('grams')})
    if out:
        return out
    for r in ((spec or {}).get('ingredients') or []):
        if isinstance(r, dict):
            out.append({'name': r.get('item') or r.get('name') or '', 'buy': r.get('buy') or '',
                        'grams': r.get('grams')})
    return out


def _source_rows(source) -> list:
    out = []
    rows = (source or {}).get('ingredients') or []
    for r in rows:
        if isinstance(r, str):
            out.append({'name': r, 'qty': '', 'unit': '', 'raw': r})
        elif isinstance(r, dict):
            out.append({'name': r.get('item') or r.get('raw') or '', 'qty': r.get('qty') or '',
                        'unit': r.get('unit') or '', 'raw': r.get('raw') or ''})
    return [r for r in out if r['name']]


def pair_rows(spec_rows, source_rows):
    """The SAME conservative head-noun pairing coverage() uses, returning indices instead of names so a
    second matcher cannot drift from the first. A missed pairing costs an unrated line; a wrong pairing
    would compare two different foods' quantities, which is worse."""
    sw = [_key(r['name']) for r in spec_rows]
    rw = [_key(r['name']) for r in source_rows]
    taken = set()
    pairs = []
    for i, w in enumerate(sw):
        hit = next((j for j in range(len(rw)) if j not in taken and _pairs(w, rw[j])), None)
        if hit is not None:
            taken.add(hit)
        pairs.append((i, hit))
    return pairs


# ---- check: scale ratio ----------------------------------------------------------------------------

def check_scale_ratio(spec, source) -> dict:
    """Every line should have been scaled by the SAME factor. A line that was not is either a deliberate
    substitution the QA agent should defend or a hand adjustment nobody recorded - and until v3 the only
    thing looking was a model reading fourteen numbers.

    The recipe's ratio is the MEDIAN of the per-line implied ratios, not the servings ratio, because the
    median is what the recipe ACTUALLY did; the servings claim is checked separately against it.
    """
    srows, rrows = _spec_rows(spec), _source_rows(source)
    lines, unrated, exempt = [], [], []
    for i, j in pair_rows(srows, rrows):
        sr = srows[i]
        if j is None:
            unrated.append({'item': sr['name'], 'why': 'no source line pairs with it (coverage owns that finding)'})
            continue
        rr = rrows[j]
        if not str(rr['qty']).strip():
            exempt.append({'item': sr['name'], 'why': 'the source states no quantity for it'})
            continue
        sa = parse_amount(sr['buy'])
        ra = parse_amount((str(rr['qty']) + ' ' + str(rr['unit'])).strip())
        if sa is None or ra is None:
            unrated.append({'item': sr['name'], 'why': "could not read a leading amount from %r / %r"
                            % (sr['buy'], (str(rr['qty']) + ' ' + str(rr['unit'])).strip())})
            continue
        sb, sf = to_base(*sa)
        rb, rf = to_base(*ra)
        if sf != rf or rb == 0:
            unrated.append({'item': sr['name'], 'why': 'the two measures are not the same kind (%s vs %s), '
                            'so a ratio needs a density this check deliberately does not carry' % (sf, rf)})
            continue
        lines.append({'item': sr['name'], 'source': '%g %s' % ra, 'spec': '%g %s' % sa,
                      'ratio': round(sb / rb, 4), '_spec_val': sa[0], '_spec_unit': sa[1], '_src_base': rb})

    ratios = [l['ratio'] for l in lines]
    med = _median(ratios)
    findings = []
    if med is None or med <= 0:
        return {'check': 'scale-ratio', 'verdict': 'fail',
                'numbers': {'rated': 0, 'unrated': len(unrated), 'exempt': len(exempt), 'recipe_ratio': None},
                'detail': 'not one ingredient line could be rated, so the scaling was not checked at all - '
                          'could-not-look is not a clean bill',
                'findings': [{'severity': 'fail', 'detail': u['item'] + ': ' + u['why']} for u in unrated]}

    for l in lines:
        dev = abs(l['ratio'] - med) / med
        # Quantization allowance: what would the exact scale have printed, in THIS line's own unit?
        expected = (l['_src_base'] * med) / max(_unit_factor(l['_spec_unit']), 1e-9)
        explained = abs(l['_spec_val'] - expected) <= QUANT_SLACK
        l['deviation'] = round(dev, 4)
        l['quantization_explained'] = bool(explained)
        if explained or dev <= RATIO_NOTE_PCT:
            l['severity'] = 'pass'
            continue
        sev = 'fail' if dev > RATIO_FAIL_PCT else 'note'
        l['severity'] = sev
        findings.append({'severity': sev, 'detail':
                         "%s scaled %.3gx while the recipe scaled %.3gx (%.1f%% off): the source says %s and "
                         "the spec buys %s, where the exact scale is %.3g %s. House quarter-quantization does "
                         "not explain it." % (l['item'], l['ratio'], med, dev * 100.0, l['source'], l['spec'],
                                              expected, l['_spec_unit'] or 'each')})
    for l in lines:
        for k in ('_spec_val', '_spec_unit', '_src_base'):
            l.pop(k, None)
    hard = [f for f in findings if f['severity'] == 'fail']
    return {'check': 'scale-ratio', 'verdict': 'fail' if hard else 'pass',
            'numbers': {'rated': len(lines), 'unrated': len(unrated), 'exempt': len(exempt),
                        'recipe_ratio': round(med, 4), 'lines': lines,
                        'unrated_lines': unrated, 'exempt_lines': exempt},
            'detail': ('every rated line scaled at the recipe''s own %.3gx (median of %d lines)' % (med, len(lines)))
                      if not findings else '; '.join(f['detail'] for f in findings),
            'findings': findings}


# ---- check: prose numbers --------------------------------------------------------------------------
# THE SCOPE IS CLAIMED-STAT NUMERALS, and that is a correction to PLAN v3 section 4.5's first wording,
# recorded in the plan itself on 2026-08-23. The plan asked for "every numeral literal in prose.* and
# head.description" to equal a stat. MEASURED against four wave-3 specs, that reads 40 legitimate
# literals as defects - oven temperatures (350), pan dimensions (9 x 13), cook times, step numbers, the
# 93/7 lean ratio - roughly ten per clean recipe, which is precisely how a guard joins the estate's dead
# guard pile. A numeral is in scope when its SURFACE FORM presents it as one of the recipe's own stats.
#
# THE PATTERNS ARE spec-contradiction-lib.ps1's, ON PURPOSE. That file is the estate's one reading of a
# self-contradicting spec and audit-spec-contradictions runs it over the whole catalog. This is the same
# reading applied per-recipe, before QA rather than at publish, EXTENDED in the two directions v3 names
# and that file does not cover: carbohydrate and fat claims, and the serving count. The self-test asserts
# the shared patterns against that file's source text, so tightening one turns the other red.

RX_CAL = re.compile(r'(?i)\b(\d{3,4})\s*cal(?:orie)?s?\b')
RX_PROTEIN = re.compile(r'(?i)\b(\d{1,3})\s*(?:g\b|grams?\b)\s*(?:of\s+)?protein')
RX_MACRO = re.compile(r'(?i)\b(\d{1,3})\s*(?:g\b|grams?\b)\s*(?:of\s+)?(carbohydrates?|carbs?|fat)\b')
# A $N.NN in one of the five prose fields is a per-serving claim by construction (spec-guards' POST-SYNC
# NUMERIC VERIFICATION says so). A BARE $N is not, and must not be: the takeout comparison the intro is
# built on is a bare $12, and every upsell in the catalog ends "all for $1 a month". Widening this to
# bare dollars was measured at 0 false positives across 513 live specs only because it was NOT widened.
RX_MONEY = re.compile(r'\$\d+\.\d{2}')
RX_CENTS = re.compile(r'(?i)\b\d{1,3}\s*cents\b')
RX_SERVINGS = re.compile(r'(?i)\b(\d{1,3})\s*(servings?|portions?|containers?|meals?)\b')
# An UPPER bound is a different claim from a quote. "under 15 grams of carbs" on an 11 g recipe is TRUE
# and it is the standard sentence in this catalog (17 of the 20 published lowcarb-100 recipes carry it).
# The exemption holds only when the bound is actually SATISFIED - "under 300 calories" on a 396-cal
# recipe still fires, because that claim is false, which is the whole point.
RX_BOUND = re.compile(r'(?i)(?<!\bnot\s)(?<!\bnever\s)(?<![a-z])'
                      r'(?:under|below|beneath|less than|fewer than|no more than|at most)\s*$')

PROSE_FIELDS = ('intro_html', 'portion_html', 'cost_closing_html', 'upsell_html', 'head.description')


def _prose_text(spec, field):
    if field == 'head.description':
        return str(((spec or {}).get('head') or {}).get('description') or '')
    return str((spec or {}).get(field) or '')


def _strip_tokens(t):
    """{{cost_ps}} and friends pass by construction - the render boundary resolves them from this spec's
    own stat, so they cannot quote a number the stat has moved away from."""
    return re.sub(r'\{\{[^}]*\}\}', ' ', t or '')


def _bounded(text, idx):
    start = max(0, idx - 24)
    return bool(RX_BOUND.search(text[start:idx]))


def check_prose_numbers(spec) -> dict:
    stat = (spec or {}).get('stat') or {}
    servings = (spec or {}).get('servings')
    findings = []
    checked = 0
    for field in PROSE_FIELDS:
        raw = _prose_text(spec, field)
        if not raw:
            continue
        t = _strip_tokens(raw)
        for m in RX_CAL.finditer(t):
            checked += 1
            claimed, actual = int(m.group(1)), int(stat.get('cal') or 0)
            if not actual:
                continue
            bad = (actual >= claimed) if _bounded(t, m.start()) else (claimed != actual)
            if bad:
                findings.append({'severity': 'fail', 'detail': '%s says %d calories, the stat says %d'
                                 % (field, claimed, actual)})
        for m in RX_PROTEIN.finditer(t):
            checked += 1
            claimed, actual = int(m.group(1)), int(stat.get('protein') or 0)
            if actual and claimed != actual:
                findings.append({'severity': 'fail', 'detail': '%s says %dg protein, the stat says %d'
                                 % (field, claimed, actual)})
        for m in RX_MACRO.finditer(t):
            checked += 1
            key = 'fat' if m.group(2).lower().startswith('fat') else 'carbs'
            claimed, actual = int(m.group(1)), int(stat.get(key) or 0)
            if not actual:
                continue
            bad = (actual >= claimed) if _bounded(t, m.start()) else (claimed != actual)
            if bad:
                findings.append({'severity': 'fail', 'detail': '%s says %dg %s, the stat says %d'
                                 % (field, claimed, key, actual)})
        cps = str(stat.get('cost_ps') or '')
        for m in RX_MONEY.finditer(t):
            checked += 1
            if cps and m.group(0) != ('$' + cps):
                findings.append({'severity': 'fail', 'detail': '%s quotes %s but the per-serving cost is $%s'
                                 % (field, m.group(0), cps)})
        for m in RX_CENTS.finditer(t):
            checked += 1
            findings.append({'severity': 'fail', 'detail': "%s quotes '%s' - a per-line cents figure from a "
                             "basis the cost redesign removed" % (field, m.group(0).strip())})
        if servings:
            for m in RX_SERVINGS.finditer(t):
                checked += 1
                if int(m.group(1)) != int(servings):
                    findings.append({'severity': 'fail', 'detail': '%s claims %s %s but the recipe makes %d'
                                     % (field, m.group(1), m.group(2), int(servings))})
    return {'check': 'prose-numbers', 'verdict': 'fail' if findings else 'pass',
            'numbers': {'stat_claims_read': checked, 'fields': list(PROSE_FIELDS)},
            'detail': ('every stat claim in the prose equals the stat it claims (%d read)' % checked)
                      if not findings else '; '.join(f['detail'] for f in findings),
            'findings': findings}


# ---- check: title, credit, source URL ----------------------------------------------------------------

def check_title_credit(spec, source) -> dict:
    findings = []
    name = str((spec or {}).get('name') or '').strip()
    if not name:
        findings.append({'severity': 'fail', 'detail': 'the spec has no name'})
    su = str((spec or {}).get('source_url') or '').strip()
    tu = str((source or {}).get('source_url') or '').strip()
    if not su:
        findings.append({'severity': 'fail', 'detail': 'the spec carries no source_url, so the recipe cannot '
                                                       'credit the page it came from'})
    elif tu and su.rstrip('/') != tu.rstrip('/'):
        findings.append({'severity': 'fail', 'detail': 'the spec credits %s but the transcription came from %s'
                         % (su, tu)})
    credit = str((spec or {}).get('credit_html') or '')
    if not credit.strip():
        findings.append({'severity': 'fail', 'detail': 'the spec has no credit_html'})
    elif su and su.rstrip('/') not in credit:
        findings.append({'severity': 'fail', 'detail': 'credit_html does not link the source_url the spec '
                                                       'declares (%s)' % su})
    return {'check': 'title-credit-url', 'verdict': 'fail' if findings else 'pass',
            'numbers': {'name': name, 'spec_source_url': su, 'transcription_source_url': tu},
            'detail': 'title present, source_url matches the transcription, and credit_html links it'
                      if not findings else '; '.join(f['detail'] for f in findings),
            'findings': findings}


# ---- check: dash sweep -------------------------------------------------------------------------------

def _walk_strings(obj):
    stack = [obj]
    while stack:
        v = stack.pop()
        if isinstance(v, str):
            yield v
        elif isinstance(v, dict):
            stack.extend(v.values())
        elif isinstance(v, (list, tuple)):
            stack.extend(v)


def check_dash_sweep(spec) -> dict:
    """Brad's rule, over EVERY string - the same walk build-v2-spec.ps1 runs at write time. Checked at
    three layers on purpose; this is the layer that reaches the QA agent."""
    findings = []
    for s in _walk_strings(spec):
        if '—' in s:
            findings.append({'severity': 'fail', 'detail': 'EM DASH: ' + s[:70]})
        elif '–' in s:
            findings.append({'severity': 'fail', 'detail': 'EN DASH: ' + s[:70]})
        if len(findings) >= 12:
            break
    return {'check': 'dash-sweep', 'verdict': 'fail' if findings else 'pass',
            'numbers': {'hits': len(findings)},
            'detail': 'no em or en dash anywhere in the spec' if not findings
                      else '; '.join(f['detail'] for f in findings),
            'findings': findings}


# ---- check: servings claim ----------------------------------------------------------------------------

def check_servings_claim(spec, source, ratio_check) -> dict:
    findings = []
    ss = (spec or {}).get('servings')
    src = (source or {}).get('servings')
    med = (ratio_check or {}).get('numbers', {}).get('recipe_ratio')
    if not ss:
        findings.append({'severity': 'fail', 'detail': 'the spec states no serving count'})
    claimed = None
    if ss and src:
        try:
            claimed = float(ss) / float(src)
        except (TypeError, ValueError, ZeroDivisionError):
            claimed = None
    if claimed and med:
        dev = abs(med - claimed) / claimed
        if dev > RATIO_FAIL_PCT:
            findings.append({'severity': 'fail', 'detail':
                             'the spec claims %s servings from a source that makes %s (a %.3gx rebuild) but the '
                             'ingredient lines actually scaled %.3gx - the yield claim and the food disagree by '
                             '%.1f%%' % (ss, src, claimed, med, dev * 100.0)})
    return {'check': 'servings-claim', 'verdict': 'fail' if findings else 'pass',
            'numbers': {'spec_servings': ss, 'source_servings': src,
                        'claimed_ratio': (round(claimed, 4) if claimed else None),
                        'measured_ratio': med},
            'detail': ('the spec makes %s servings and the ingredient lines scaled to match' % ss)
                      if not findings else '; '.join(f['detail'] for f in findings),
            'findings': findings}


# ---- the battery -------------------------------------------------------------------------------------

def battery(spec, source, slug=None, spec_path='', source_path='') -> dict:
    cov = coverage(spec, source)
    cov_check = {'check': 'ingredient-coverage',
                 'verdict': cov['verdict'],
                 'numbers': {'spec_ingredients': cov['spec_ingredients'],
                             'source_ingredients': cov['source_ingredients'],
                             'matched': cov['matched'], 'invented': cov['invented'],
                             'dropped': cov['dropped'], 'consolidated': cov.get('consolidated', [])},
                 'detail': ('%d of %d source ingredients pair with the spec, nothing invented, nothing dropped'
                            % (cov['matched'], cov['source_ingredients'])) if cov['verdict'] == 'pass'
                           else '; '.join(f['detail'] for f in cov['findings']),
                 'findings': [{'severity': f['severity'], 'detail': f['detail']} for f in cov['findings']]}
    ratio = check_scale_ratio(spec, source)
    checks = [cov_check, ratio, check_prose_numbers(spec), check_title_credit(spec, source),
              check_dash_sweep(spec), check_servings_claim(spec, source, ratio)]
    failed = [c for c in checks if c['verdict'] == 'fail']
    return {
        'battery': 'qa-battery',
        'version': BATTERY_VERSION,
        'slug': slug or (spec or {}).get('slug') or '',
        'generated': datetime.datetime.now().replace(microsecond=0).isoformat(),
        'inputs': {'spec': spec_path, 'source': source_path},
        'checks': checks,
        'summary': {'checks': len(checks), 'failed': len(failed)},
        # Said plainly so nobody reads a green battery as a passed QA. Each of these is the agent's, and
        # the agent may re-derive anything above it as well.
        'not_checked': [
            'whether a substitution was deliberate and defensible',
            'whether the METHOD still cooks the source dish',
            'dish identity - is this the recipe we said we found',
            'anything the live source page says that the transcription did not capture',
        ],
    }


# ---------------------------------------------------------------------------------------------------
# SELF-TEST. Every check ships its founding case first and its clean twin beside it, because a check
# that reports nothing is indistinguishable from a check that is broken.
#   python meal-prep/pipeline/coverage_check.py --selftest
# ---------------------------------------------------------------------------------------------------

def _selftest() -> int:
    fails = []

    def T(msg, cond, got=''):
        if cond:
            print('ok    ' + msg)
        else:
            print('FAIL  ' + msg + ('   got: ' + str(got) if got != '' else ''))
            fails.append(msg)

    # ---- the shape reader ------------------------------------------------------------------------
    # THE FOUNDING CASE, frozen 2026-08-23: a v2 BUILT spec keeps its ingredient lines in scaler.ing, not
    # in an `ingredients` array, so this function read zero of them and every source line came back as a
    # false DROPPED. That is the shape recipe-source-qa is actually handed.
    built_like = {'slug': 'fx', 'scaler': {'ing': [{'item': 'Hickory Smoked Bacon', 'canon': 'Hickory Smoked Bacon'},
                                                   {'item': 'Yellow Onion', 'canon': 'Yellow Onion'}]}}
    T('MUST FIRE  a v2 built spec (scaler.ing) yields its ingredient names, not an empty list',
      len(_names(built_like)) == 2, _names(built_like))
    T("CLEAN TWIN a transcription still reads through the same door",
      _names({'ingredients': [{'item': 'bacon', 'raw': '4 slices of bacon'}]}) == ['bacon'],
      _names({'ingredients': [{'item': 'bacon', 'raw': '4 slices of bacon'}]}))
    T('CLEAN TWIN an intake (ingredients[]) still reads through the same door',
      _names({'ingredients': [{'item': 'Yellow Onion', 'grams': 201}]}) == ['Yellow Onion'], '')
    T('the CANON name wins over a display rename, so a renamed line is not read as a different food',
      _names({'scaler': {'ing': [{'item': 'Glass Noodles', 'canon': 'Sweet Potato Starch Noodles'}]}})
      == ['Sweet Potato Starch Noodles'], '')
    covered = coverage(built_like, {'ingredients': [{'item': 'bacon'}, {'item': 'onion'}]})
    T('MUST FIRE  and coverage over a real built spec now matches instead of dropping everything',
      covered['verdict'] == 'pass' and covered['matched'] == 2, covered)

    # ---- compound source lines --------------------------------------------------------------------
    salt_spec = {'scaler': {'ing': [{'item': 'Salt'}, {'item': 'Black Pepper'}]}}
    salt_src = {'ingredients': [{'item': 'salt and pepper', 'raw': 'salt and pepper to taste'}]}
    T('MUST FIRE  "salt and pepper" is TWO requirements, and a spec carrying both satisfies them',
      coverage(salt_spec, salt_src)['verdict'] == 'pass', coverage(salt_spec, salt_src))
    half = coverage({'scaler': {'ing': [{'item': 'Salt'}]}}, salt_src)
    T('MUST FIRE  and splitting AND makes it STRICTER - a spec that forgot the pepper now fails',
      half['verdict'] == 'fail' and any('pepper' in d for d in half['dropped']), half['dropped'])
    or_spec = {'scaler': {'ing': [{'item': '80/20 Ground Beef'}]}}
    or_src = {'ingredients': [{'item': 'ground beef or ground turkey'}]}
    T('CLEAN TWIN "ground beef or ground turkey" is a CHOICE the source offered, so picking beef '
      'invents nothing', coverage(or_spec, or_src)['verdict'] == 'pass', coverage(or_spec, or_src))
    T('CLEAN TWIN "water or chicken broth" is satisfied by chicken broth',
      coverage({'scaler': {'ing': [{'item': 'Chicken Broth'}]}},
               {'ingredients': [{'item': 'water or chicken broth'}]})['verdict'] == 'pass', '')
    T('MUST FIRE  an or-line satisfied by NEITHER alternative is still dropped',
      coverage({'scaler': {'ing': [{'item': 'Coconut Milk'}]}}, or_src)['verdict'] == 'fail', '')
    T('a parenthetical is a note about the food, not the food: oil-packed tomatoes still pair',
      coverage({'scaler': {'ing': [{'item': 'Sun-Dried Tomatoes (Oil-Packed)'}]}},
               {'ingredients': [{'item': 'sun-dried tomatoes'}]})['verdict'] == 'pass', '')
    # ...and the head-noun rule it protects must still separate two different foods.
    T('MUST FIRE  the cut substitution the head-noun rule exists to catch still fires',
      coverage({'scaler': {'ing': [{'item': 'Boneless Skinless Chicken Breast'}]}},
               {'ingredients': [{'item': 'chicken thighs'}]})['verdict'] == 'fail', '')

    T('a compound spelling is one food: "Panko Breadcrumbs" pairs with "panko bread crumbs"',
      coverage({'scaler': {'ing': [{'item': 'Panko Breadcrumbs'}]}},
               {'ingredients': [{'item': 'panko bread crumbs'}]})['verdict'] == 'pass', '')
    T('MUST FIRE  the compound rule is narrow - broth and stock are still different foods',
      coverage({'scaler': {'ing': [{'item': 'Chicken Broth'}]}},
               {'ingredients': [{'item': 'chicken stock'}]})['verdict'] == 'fail', '')

    # A SECTIONED SOURCE lists the same food under two headings and the spec carries one line.
    sect = coverage({'scaler': {'ing': [{'item': 'Garlic Powder'}, {'item': 'Olive Oil'}]}},
                    {'ingredients': [{'item': 'garlic powder'}, {'item': 'olive oil'},
                                     {'item': 'garlic powder'}]})
    T('a food the source lists twice and the spec carries once is CONSOLIDATED, not dropped',
      sect['verdict'] == 'pass' and len(sect['consolidated']) == 1 and not sect['dropped'], sect)
    T('...and the consolidation is still SAID, because the summed amount is a real question',
      any(f['severity'] == 'note' and 'CONSOLIDATED' in f['detail'] for f in sect['findings']), sect['findings'])
    T('MUST FIRE  a food listed twice and carried ZERO times is still a DROP',
      coverage({'scaler': {'ing': [{'item': 'Olive Oil'}]}},
               {'ingredients': [{'item': 'garlic powder'}, {'item': 'olive oil'},
                                {'item': 'garlic powder'}]})['verdict'] == 'fail', '')

    # ---- the quantity reader -------------------------------------------------------------------
    # ---- stated_mass_grams, AND ITS POWERSHELL TWIN --------------------------------------------
    # Get-StatedMassGrams in map-preresolve.ps1 answers this same question for the mapper. The two
    # must agree: same units, same conservative refusals, first mass token only. If you change one,
    # change both - this estate has shipped the same rule twice and watched the copies drift apart
    # until they fired on disjoint inputs.
    T("MUST FIRE  a line stating BOTH a count and a weight yields the WEIGHT - the count is packaging",
      abs(stated_mass_grams('2 medium 1.5 lbs. chicken breasts') - 680.388) < 0.2,
      stated_mass_grams('2 medium 1.5 lbs. chicken breasts'))
    T("  ...and parse_amount still answers its OWN question on that line, unchanged",
      parse_amount('2 medium 1.5 lbs. chicken breasts') == (2.0, 'medium'),
      parse_amount('2 medium 1.5 lbs. chicken breasts'))
    T("MUST FIRE  ounces, grams, kilograms and a fraction all read",
      abs(stated_mass_grams('14.5 oz black olives') - 411.07) < 0.1
      and stated_mass_grams('600 g chicken tenderloin') == 600
      and stated_mass_grams('1.8 kg whole chicken') == 1800
      and abs(stated_mass_grams('1/2 lb ground beef') - 226.796) < 0.1, 'unit table')
    T("CLEAN TWIN a VOLUME is not a mass", stated_mass_grams('1 cup buttermilk') is None
      and stated_mass_grams('3 tablespoons honey') is None, 'volume read as mass')
    T("CLEAN TWIN a bare count states no mass", stated_mass_grams('2 medium yellow onions') is None,
      stated_mass_grams('2 medium yellow onions'))
    T("CLEAN TWIN zero is not a mass", stated_mass_grams('0 lb nothing') is None,
      stated_mass_grams('0 lb nothing'))

    T("'3 1/2 lb (80/20)' reads as 3.5 lb, not 3", parse_amount('3 1/2 lb (80/20)') == (3.5, 'lb'),
      parse_amount('3 1/2 lb (80/20)'))
    T("'1 3/4 cups chopped (about 2 medium)' reads as 1.75 cup", parse_amount('1 3/4 cups chopped (about 2 medium)') == (1.75, 'cup'),
      parse_amount('1 3/4 cups chopped (about 2 medium)'))
    T("'14 slices, chopped into small pieces' reads as 14 slice", parse_amount('14 slices, chopped into small pieces') == (14.0, 'slice'),
      parse_amount('14 slices, chopped into small pieces'))
    T("'7 tbsp (a bit under 1/2 cup)' takes the LEADING amount, not the parenthetical",
      parse_amount('7 tbsp (a bit under 1/2 cup)') == (7.0, 'tbsp'), parse_amount('7 tbsp (a bit under 1/2 cup)'))
    # THE FOUNDING CASE of this parser, frozen 2026-08-23: a single greedy regex read '1/2 cup' as ONE
    # cup with no unit, so every half-cup line fell out of the ratio check as UNRATED - and the clean
    # twin still passed, because the lines that remained all scaled correctly.
    T("MUST FIRE  '1/2 cup' is half a cup, not one cup with no unit",
      parse_amount('1/2 cup') == (0.5, 'cup'), parse_amount('1/2 cup'))
    T("'1/4 teaspoon' is a quarter teaspoon", parse_amount('1/4 teaspoon') == (0.25, 'teaspoon'),
      parse_amount('1/4 teaspoon'))
    # The spelling is kept as written (it reads better in the report); what has to be true is that the
    # two spellings CONVERT the same, because a ratio is taken across them.
    T("'tsp' and 'teaspoon' are the same measure once converted",
      to_base(3, 'tsp') == to_base(3, 'teaspoon') and to_base(1, 'tbsp') == to_base(3, 'tsp'),
      (to_base(3, 'tsp'), to_base(3, 'teaspoon')))
    T("'1/2' with no unit reads as a bare count", parse_amount('1/2') == (0.5, ''), parse_amount('1/2'))
    T("'1-1/2 cups' glued-mixed reads as 1.5 cup", parse_amount('1-1/2 cups') == (1.5, 'cup'),
      parse_amount('1-1/2 cups'))
    T("'.75 lb' with a leading dot reads as 0.75 lb", parse_amount('.75 lb') == (0.75, 'lb'),
      parse_amount('.75 lb'))
    T("MUST REFUSE  'to taste' has no amount, and None is not zero", parse_amount('to taste') is None,
      parse_amount('to taste'))
    T("MUST REFUSE  an empty measure has no amount", parse_amount('') is None, parse_amount(''))
    T('a vulgar fraction is read', parse_amount('½ cup') == (0.5, 'cup'), parse_amount('½ cup'))
    T('volume and weight are different families, so they are never compared',
      to_base(1, 'cup')[1] != to_base(1, 'lb')[1], (to_base(1, 'cup'), to_base(1, 'lb')))
    T("a count noun is its own family - 'slice' can only meet 'slice'",
      to_base(4, 'slice')[1] == 'count:slice' and to_base(4, 'clove')[1] == 'count:clove', '')

    # ---- scale ratio ----------------------------------------------------------------------------
    def mk(spec_ing, src_ing, spec_servings=14, src_servings=4, **kw):
        spec = {'slug': 'fx', 'name': 'Fixture', 'servings': spec_servings,
                'source_url': 'https://example.com/r/', 'credit_html': '<a href="https://example.com/r/">x</a>',
                'stat': {'cal': 500, 'protein': 30, 'carbs': 10, 'fat': 30, 'cost_ps': '2.50'},
                'scaler': {'ing': spec_ing}}
        spec.update(kw)
        src = {'servings': src_servings, 'source_url': 'https://example.com/r/', 'ingredients': src_ing}
        return spec, src

    even_spec = [{'item': 'Ground Beef', 'buy': '3 1/2 lb', 'grams': 1588},
                 {'item': 'Yellow Onion', 'buy': '1 3/4 cups chopped', 'grams': 201},
                 {'item': 'Tomato Paste', 'buy': '7 tbsp', 'grams': 112}]
    even_src = [{'item': 'ground beef', 'qty': '1', 'unit': 'pound', 'raw': '1 pound ground beef'},
                {'item': 'onion', 'qty': '1/2', 'unit': 'cup', 'raw': '1/2 cup chopped onion'},
                {'item': 'tomato paste', 'qty': '2', 'unit': 'tablespoon', 'raw': '2 tablespoons tomato paste'}]
    spec, src = mk(even_spec, even_src)
    r = check_scale_ratio(spec, src)
    T('CLEAN TWIN a recipe scaled evenly at 3.5x reports nothing',
      r['verdict'] == 'pass' and abs(r['numbers']['recipe_ratio'] - 3.5) < 1e-6, r['detail'])

    # THE FOUNDING CASE: one line hand-adjusted while the rest scaled. The onion is doubled again.
    hand = [dict(even_spec[0]), {'item': 'Yellow Onion', 'buy': '3 1/2 cups chopped', 'grams': 402},
            dict(even_spec[2])]
    spec, src = mk(hand, even_src)
    r = check_scale_ratio(spec, src)
    T('MUST FIRE  one hand-adjusted line is caught against the recipe''s own median ratio',
      r['verdict'] == 'fail' and 'Yellow Onion' in r['detail'], r['detail'])

    # THE HOUSE QUARTER. 1/4 tsp x 3.5 = 0.875, which the mapper quantizes to 1 tsp - a 14% deviation
    # that is the convention working. A check that fired here would fire on nearly every spice line.
    quant_spec = list(even_spec) + [{'item': 'Kosher Salt', 'buy': '1 tsp', 'grams': 6}]
    quant_src = list(even_src) + [{'item': 'salt', 'qty': '1/4', 'unit': 'teaspoon', 'raw': '1/4 tsp salt'}]
    spec, src = mk(quant_spec, quant_src)
    r = check_scale_ratio(spec, src)
    salt = [l for l in r['numbers']['lines'] if l['item'] == 'Kosher Salt'][0]
    T('CLEAN TWIN a small measure rounded to the house quarter does not read as a hand adjustment',
      r['verdict'] == 'pass' and salt['quantization_explained'], '%s dev=%s' % (r['detail'], salt.get('deviation')))
    # ...and the allowance must not swallow a REAL adjustment on the same small line
    big_spec = list(even_spec) + [{'item': 'Kosher Salt', 'buy': '3 tsp', 'grams': 18}]
    spec, src = mk(big_spec, quant_src)
    r = check_scale_ratio(spec, src)
    T('MUST FIRE  the quarter allowance does not swallow a tripled spice line',
      r['verdict'] == 'fail' and 'Kosher Salt' in r['detail'], r['detail'])

    spec, src = mk(even_spec, [dict(x) for x in even_src[:2]] + [{'item': 'tomato paste', 'qty': '', 'unit': '', 'raw': 'tomato paste to taste'}])
    r = check_scale_ratio(spec, src)
    T('a line the source states without a quantity is EXEMPT, not a finding',
      r['verdict'] == 'pass' and r['numbers']['exempt'] == 1, r['detail'])
    spec, src = mk([{'item': 'Yellow Onion', 'buy': '7 oz chopped', 'grams': 201}],
                   [{'item': 'onion', 'qty': '1/2', 'unit': 'cup', 'raw': '1/2 cup onion'}])
    r = check_scale_ratio(spec, src)
    T('MUST SAY SO  a cup-against-ounces line is UNRATED, never guessed with a density this file lacks',
      r['numbers']['unrated'] == 1, r['numbers'])
    T('MUST FIRE  a recipe where NOTHING could be rated fails - could-not-look is not a clean bill',
      check_scale_ratio(*mk([{'item': 'Salt', 'buy': 'to taste', 'grams': 1}],
                            [{'item': 'salt', 'qty': 'a', 'unit': 'pinch', 'raw': 'a pinch'}]))['verdict'] == 'fail', '')

    # ---- prose numbers ----------------------------------------------------------------------------
    base = {'stat': {'cal': 524, 'protein': 31, 'carbs': 6, 'fat': 40, 'cost_ps': '2.66'}, 'servings': 14}
    T('CLEAN TWIN prose quoting the stat exactly passes',
      check_prose_numbers(dict(base, intro_html='524 calories and 31 grams of protein a serving for $2.66'))['verdict'] == 'pass',
      check_prose_numbers(dict(base, intro_html='524 calories and 31 grams of protein a serving for $2.66'))['detail'])
    # THE FOUNDING CASE, 2026-07-26: a portion paragraph claiming 499 calories on a 541-calorie recipe.
    T('MUST FIRE  a calorie figure that is not the stat is caught',
      check_prose_numbers(dict(base, portion_html='a 499 calorie bowl'))['verdict'] == 'fail', '')
    T('MUST FIRE  a protein figure that is not the stat is caught',
      check_prose_numbers(dict(base, intro_html='40 grams of protein a serving'))['verdict'] == 'fail', '')
    # THE CARB/FAT EXTENSION, which spec-contradiction-lib does not cover and v3 asks for.
    T('MUST FIRE  a CARB figure that is not the stat and is not a bound is caught',
      check_prose_numbers(dict(base, intro_html='exactly 20 grams of carbs a serving'))['verdict'] == 'fail', '')
    # ...but the catalog's standard sentence is a TRUE upper bound and must stay quiet. Measured: 17 of
    # the 20 published lowcarb-100 recipes say "with under N grams of carbs" with N above the stat.
    T('CLEAN TWIN "under 10 grams of carbs" on a 6 g recipe is a true bound, not a stale number',
      check_prose_numbers(dict(base, intro_html='with under 10 grams of carbs'))['verdict'] == 'pass',
      check_prose_numbers(dict(base, intro_html='with under 10 grams of carbs'))['detail'])
    T('MUST FIRE  "under 5 grams of carbs" on a 6 g recipe is a FALSE bound and still fires',
      check_prose_numbers(dict(base, intro_html='with under 5 grams of carbs'))['verdict'] == 'fail', '')
    T('MUST FIRE  "not under 400 calories" is not a bound - a negated bound claims the opposite',
      check_prose_numbers(dict(base, intro_html='not under 400 calories'))['verdict'] == 'fail', '')
    T('CLEAN TWIN "under 600 calories" on a 524-cal recipe is true and stays quiet',
      check_prose_numbers(dict(base, intro_html='under 600 calories'))['verdict'] == 'pass', '')
    # THE 2026-08-07 CASE: a portion line saying "$2.00 a bowl" beside a closing line saying "$4.87".
    T('MUST FIRE  a $N.NN that is not the per-serving cost is caught in every prose field',
      check_prose_numbers(dict(base, portion_html='at roughly $2.00 a bowl'))['verdict'] == 'fail', '')
    T('CLEAN TWIN the bare $1-a-month upsell and a bare takeout $12 are NOT per-serving claims',
      check_prose_numbers(dict(base, upsell_html='all for $1 a month', intro_html='takeout runs $12'))['verdict'] == 'pass',
      check_prose_numbers(dict(base, upsell_html='all for $1 a month', intro_html='takeout runs $12'))['detail'])
    T('CLEAN TWIN a {{cost_ps}} token passes by construction',
      check_prose_numbers(dict(base, cost_closing_html='about ${{cost_ps}} a serving'))['verdict'] == 'pass', '')
    T('MUST FIRE  a serving-count claim that is not the recipe''s is caught',
      check_prose_numbers(dict(base, portion_html='divide into 12 containers'))['verdict'] == 'fail', '')
    T('CLEAN TWIN the right serving count passes', check_prose_numbers(dict(base, portion_html='divide into 14 containers'))['verdict'] == 'pass', '')
    # THE SCOPE CORRECTION, frozen. Oven temperature, pan size, cook time and a lean ratio are NOT stat
    # claims, and a rule that read every numeral fired on 40 of them across four real wave-3 specs.
    noise = dict(base, portion_html='Bake at 350 degrees in a 9 by 13 pan for 25 minutes, 93/7 beef, step 2')
    T('CLEAN TWIN oven temps, pan sizes, cook times and 93/7 are not stat claims and never fire',
      check_prose_numbers(noise)['verdict'] == 'pass', check_prose_numbers(noise)['detail'])

    # ---- title / credit / url ----------------------------------------------------------------------
    good_spec, good_src = mk(even_spec, even_src)
    T('CLEAN TWIN a spec crediting the page it was transcribed from passes',
      check_title_credit(good_spec, good_src)['verdict'] == 'pass', check_title_credit(good_spec, good_src)['detail'])
    T('MUST FIRE  a spec crediting a DIFFERENT page than the transcription is caught',
      check_title_credit(dict(good_spec, source_url='https://elsewhere.com/x/'), good_src)['verdict'] == 'fail', '')
    T('MUST FIRE  a missing credit block is caught',
      check_title_credit(dict(good_spec, credit_html=''), good_src)['verdict'] == 'fail', '')
    T('MUST FIRE  a credit block that does not link the declared source is caught',
      check_title_credit(dict(good_spec, credit_html='<p>adapted from somewhere</p>'), good_src)['verdict'] == 'fail', '')

    # ---- dash sweep ---------------------------------------------------------------------------------
    T('MUST FIRE  an em dash anywhere in the spec is found',
      check_dash_sweep({'prose': {'a': 'a fine line—and then some'}})['verdict'] == 'fail', '')
    T('MUST FIRE  an en dash is found too', check_dash_sweep({'a': ['range 4–6']})['verdict'] == 'fail', '')
    T('CLEAN TWIN hyphens are not dashes', check_dash_sweep({'a': 'low-carb, high-protein'})['verdict'] == 'pass', '')

    # ---- servings claim -----------------------------------------------------------------------------
    spec, src = mk(even_spec, even_src)
    rr = check_scale_ratio(spec, src)
    T('CLEAN TWIN a 14-from-4 claim agrees with a 3.5x ingredient scale',
      check_servings_claim(spec, src, rr)['verdict'] == 'pass', check_servings_claim(spec, src, rr)['detail'])
    T('MUST FIRE  a spec claiming 14 servings whose food only scaled 3.5x from a 6-serving source is caught',
      check_servings_claim(dict(spec), dict(src, servings=6), rr)['verdict'] == 'fail', '')

    # ---- the lockstep fixture -----------------------------------------------------------------------
    # spec-contradiction-lib.ps1 is the estate's ONE reading of a self-contradicting spec, and
    # audit-spec-contradictions.ps1 runs it over the whole catalog. These patterns are that reading. If
    # it is tightened and this file is not, the two disagree silently and the audit certifies a repair it
    # does not describe - which is the exact class of bug that file's own header exists to prevent.
    lib = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'spec-contradiction-lib.ps1')
    if os.path.exists(lib):
        with io.open(lib, encoding='utf-8-sig', errors='replace') as fh:
            src_ps = fh.read()
        T('LOCKSTEP  the calorie pattern still matches spec-contradiction-lib.ps1',
          RX_CAL.pattern.replace('(?i)', '') in src_ps, RX_CAL.pattern)
        T('LOCKSTEP  the protein pattern still matches spec-contradiction-lib.ps1',
          RX_PROTEIN.pattern.replace('(?i)', '') in src_ps, RX_PROTEIN.pattern)
        T('LOCKSTEP  the $N.NN money pattern still matches spec-contradiction-lib.ps1',
          RX_MONEY.pattern.replace('\\$', '\\$') in src_ps, RX_MONEY.pattern)
        T('LOCKSTEP  the upper-bound word list still matches spec-contradiction-lib.ps1',
          'under|below|beneath|less than|fewer than|no more than|at most' in src_ps, '')
    else:
        T('LOCKSTEP  spec-contradiction-lib.ps1 is readable so the patterns can be compared', False, 'not found')

    # ---- COMPOSITE TERM SPLITTING (2026-08-26) ------------------------------------------------------
    # The founding case: run hunt-2026-08-26-ten shipped nothing, and "Salt and Pepper" was the single
    # named blocker on two of the twelve STUCK recipes. The food DB cannot carry a row for two foods.
    # The head set is the REAL one, read from the live vocabulary and food DB, so a fixture cannot pass
    # on a hand-picked set that the estate does not actually have.
    _root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    _voc, _fdb = [], []
    try:
        with io.open(os.path.join(_root, 'db', 'ingredients.json'), encoding='utf-8-sig') as fh:
            _voc = [r.get('item') for r in json.load(fh) if isinstance(r, dict) and r.get('item')]
        with io.open(os.path.join(_root, 'food-macros-db.json'), encoding='utf-8-sig') as fh:
            _fdb = [r.get('item') for r in json.load(fh).get('items', []) if r.get('item')]
    except Exception as _exc:                                       # noqa: BLE001
        _voc, _fdb = [], []
    T('the live vocabulary and food DB are readable, so the split fixtures run on real head nouns',
      len(_voc) > 200 and len(_fdb) > 200, 'vocab=%d fooddb=%d' % (len(_voc), len(_fdb)))
    H = known_heads(_voc, _fdb)
    T('MUST FIRE  "Salt and Pepper" is TWO foods and splits - it is the term that took two recipes '
      'STUCK at the write lane on 2026-08-26',
      split_composite('Salt and Pepper', H) == ['Salt', 'Pepper'],
      split_composite('Salt and Pepper', H))
    T('MUST FIRE  a comma enumeration splits into all THREE, not two - "a, b, and c" is the shape '
      'that parked quinoa-casserole-with-chicken',
      split_composite('Garlic Powder, Cumin, and Chili Powder', H)
      == ['Garlic Powder', 'Cumin', 'Chili Powder'],
      split_composite('Garlic Powder, Cumin, and Chili Powder', H))
    T('MUST FIRE  ...and the mixed comma-then-and shape too, which parked peach-chicken',
      split_composite('Dried Thyme, Dried Basil and Onion Powder', H)
      == ['Dried Thyme', 'Dried Basil', 'Onion Powder'],
      split_composite('Dried Thyme, Dried Basil and Onion Powder', H))
    # THE GUARDS. A false split up at term formation buys a second shopping line and a second priced
    # ingredient, so each of these is a case the estate would have got WRONG without its own guard.
    # THE HEAD-NOUN GUARD, ON ITS OWN. This phrase is NOT on the denylist, so nothing else here can
    # keep it whole: "Freshly Ground" is a truncated modifier, its head noun is 'freshly', and no
    # vocabulary or food-DB item ends in that word. Neuter the head test and this fixture fires.
    T('MUST FIRE  a part that is a MODIFIER FRAGMENT, not a food, stops the split - "Freshly Ground" '
      'has no head noun the estate knows',
      split_composite('Salt and Freshly Ground', H) == [],
      split_composite('Salt and Freshly Ground', H))
    T('CLEAN TWIN "Sweet and Sour Sauce" and "Macaroni and Cheese" are ONE food each - the head-noun '
      'test alone would hold both, and the denylist holds them again',
      split_composite('Sweet and Sour Sauce', H) == [] and split_composite('Macaroni and Cheese', H) == [],
      '%s / %s' % (split_composite('Sweet and Sour Sauce', H), split_composite('Macaroni and Cheese', H)))
    # THE RESOLVED-WHOLE GUARD, ON ITS OWN, asserted as the DIFFERENCE it makes: the same phrase that
    # splits when the estate does not carry it stays whole the moment the estate does. That is what
    # keeps a real product like Half and Half - a live row in this very food DB - from becoming two.
    T('MUST FIRE  a term the estate ALREADY resolves as a whole is NEVER split, however its name '
      'reads, and the very same term splits when it does not',
      split_composite('Salt and Pepper', H, resolved_whole=True) == []
      and split_composite('Salt and Pepper', H) == ['Salt', 'Pepper'],
      '%s vs %s' % (split_composite('Salt and Pepper', H, resolved_whole=True),
                    split_composite('Salt and Pepper', H)))
    T('MUST FIRE  the denylist holds a fixed compound whose halves are BOTH known heads',
      split_composite('Bread and Butter Pickles', H) == [],
      split_composite('Bread and Butter Pickles', H))
    T('MUST FIRE  a five-part list is a section heading, not an ingredient line, and is left whole',
      split_composite('sour cream, cilantro, lime, jalapeno, and cheddar cheese', H) == [],
      split_composite('sour cream, cilantro, lime, jalapeno, and cheddar cheese', H))
    # NEUTER PROOF, RUN AND REVERTED 2026-08-26: delete the four label-strip lines from
    # split_composite -> 3 RED (the label case, the survive case and the enumeration clause). The
    # "still left whole" case and the clean twin stay green, which is correct - neither turns on the
    # strip, and a neuter that reddens everything proves nothing about which case tests what.
    #
    # THE HEADING SHAPE THE FIVE-PART CAP CANNOT REACH (2026-08-26), measured on easy-beef-enchiladas
    # in run hunt-2026-08-26-smoke. Four parts, so the cap passes it, and _words strips the colon, so
    # the first part's head noun reads as 'onion' and the head guard passes it too. Without the label
    # road this splits and hands the batch "Optional Toppings: Diced Onion" as a food.
    T('MUST FIRE  a heading LABEL before a comma list is stripped, not carried into the first part - '
      "'Optional Toppings: Diced Onion' is a term no food DB can ever carry a row for",
      split_composite('Optional Toppings: Diced Onion, Cilantro, Sour Cream', H)
      == ['Diced Onion', 'Cilantro', 'Sour Cream'],
      split_composite('Optional Toppings: Diced Onion, Cilantro, Sour Cream', H))
    # AND THE MEASURED TERM ITSELF IS STILL LEFT WHOLE, WHICH IS RECORDED HERE RATHER THAN QUIETLY
    # NOT TESTED. 'Shredded Lettuce' has the head noun 'lettuce' and no vocabulary or food-DB item in
    # this estate ends in it, so the head guard refuses the whole split - correctly, by its own rule -
    # and the heading reaches the mapper as one term exactly as it did on 2026-08-26. The label road
    # fixes the SHAPE and does not fix this line; what stops this line sailing past the map lane is
    # the food-row postcondition in hunt-daemon.py, which now demands a row or a stated absence for
    # it and holds the recipe when neither arrives. Add 'lettuce' to the estate and this case flips,
    # which is why it asserts the reason and not just the empty list.
    T('MUST FIRE  the measured enchiladas term is STILL left whole, and the head noun the estate '
      "lacks is why - the label road fixed the shape, not this line",
      split_composite('Optional Toppings: Diced Onion, Cilantro, Sour Cream, Shredded Lettuce', H)
      == [] and _head(_words('Shredded Lettuce')) not in H,
      'split=%s lettuce_head_known=%s'
      % (split_composite('Optional Toppings: Diced Onion, Cilantro, Sour Cream, Shredded Lettuce', H),
         _head(_words('Shredded Lettuce')) in H))
    T('MUST FIRE  ...and the foods UNDER the heading survive it - refusing the line would drop three '
      'real ingredients, which is why the label is stripped rather than the term left whole',
      split_composite('For the sauce: soy sauce, honey, and garlic', H)
      == ['soy sauce', 'honey', 'garlic'],
      split_composite('For the sauce: soy sauce, honey, and garlic', H))
    # THE ENUMERATION CLAUSE, ASSERTED AS THE DIFFERENCE IT MAKES - the same label, once over a list
    # and once over a single food. Only the first is a heading; the second is one ingredient with a
    # note in front of it, and a bare "soy sauce" must not become a part of anything.
    T('MUST FIRE  a colon with NO list after it is not a heading and nothing is stripped, while the '
      'very same label over a list is',
      split_composite('For the sauce: soy sauce', H) == []
      and len(split_composite('For the sauce: soy sauce, honey, and garlic', H)) == 3,
      '%s vs %s' % (split_composite('For the sauce: soy sauce', H),
                    split_composite('For the sauce: soy sauce, honey, and garlic', H)))
    T('CLEAN TWIN a food with a measurement note behind a colon is left whole - the head-noun guard '
      'rules the fragment exactly as it did before the label road existed',
      split_composite('Chicken Thighs, boneless: 2 lbs', H) == [],
      split_composite('Chicken Thighs, boneless: 2 lbs', H))
    T('MUST FIRE  two parts denoting the SAME food are one food said twice and never split - a '
      'duplicate line would put one ingredient on the card twice',
      split_composite('Chicken Broth and Chicken Broth', H) == [],
      split_composite('Chicken Broth and Chicken Broth', H))
    T('CLEAN TWIN an ordinary single-food term is untouched',
      split_composite('Boneless Skinless Chicken Breast', H) == [], '')
    # LOCKSTEP: this road and the coverage check split the same way on the founding phrase, because
    # they read the same _words/_head. If one is tightened and the other is not, a spec that carries
    # two lines would satisfy two requirements here and one there.
    T('LOCKSTEP  the coverage check reads "salt and pepper to taste" as two requirements too',
      len(_requirements(['salt and pepper to taste'])) == 2,
      [r['text'] for r in _requirements(['salt and pepper to taste'])])

    # ---- the battery as a whole ------------------------------------------------------------------------
    spec, src = mk(even_spec, even_src, intro_html='524 calories', name='Fixture')
    spec['stat']['cal'] = 524
    b = battery(spec, src, slug='fx')
    T('the battery returns one report with every check in it',
      b['summary']['checks'] == 6 and all('verdict' in c for c in b['checks']), b['summary'])
    T('a check renders as {check, verdict, numbers, detail, findings}',
      all(set(('check', 'verdict', 'numbers', 'detail', 'findings')) <= set(c) for c in b['checks']), '')
    T('the report says out loud what it did NOT check', len(b['not_checked']) >= 3, '')

    print('')
    if not fails:
        print('qa-battery SELF-TEST PASS')
        return 0
    print('qa-battery SELF-TEST FAIL: %d case(s)' % len(fails))
    return 1


def main() -> int:
    ap = argparse.ArgumentParser(description="QA battery: coverage, scaling, prose numbers, credit, dashes")
    ap.add_argument("--spec")
    ap.add_argument("--source")
    ap.add_argument("--json", action="store_true")
    # --battery runs EVERY check and writes the machine report the QA dispatch reads. The bare
    # --spec/--source form is unchanged on purpose: it is coverage only, it is what
    # .claude\agents\recipe-source-qa.md has always called, and breaking it to add a feature would be
    # the kind of silent contract change this pipeline cannot afford.
    ap.add_argument("--battery", action="store_true",
                    help="run the whole QA battery and write <slug>.battery.json")
    ap.add_argument("--out", default="", help="battery report path (default <RunDir>/qa/<slug>.battery.json "
                                              "when --run-dir is given, else beside the spec)")
    ap.add_argument("--run-dir", default="")
    ap.add_argument("--selftest", action="store_true")
    # --split-terms is the TERM-FORMATION road and it takes neither --spec nor --source. One call per
    # map batch, exactly like the vocabulary and board lookups beside it: stdin carries
    # {terms:[...], resolved:[...], names:[...]} and stdout carries {parts:{term:[part,...]}}, holding
    # only the terms that actually split. Kept in this file because it is THIS file's head-noun
    # scoring; a PowerShell reimplementation would be a second taxonomy.
    ap.add_argument("--split-terms", action="store_true",
                    help="read {terms, resolved, names} on stdin, write {parts} on stdout")
    args = ap.parse_args()

    if args.selftest:
        return _selftest()
    if args.split_terms:
        try:
            # PowerShell's pipe into a native exe writes a UTF-8 BOM ahead of the payload, and
            # json.loads calls that "Unexpected UTF-8 BOM". Measured 2026-08-26 by this road's own
            # map-preresolve fixture, which is the only caller and is a PowerShell one.
            req = json.loads(_strip_bom(sys.stdin.read()))
        except Exception as exc:                                    # noqa: BLE001
            # Exit 2 is could-not-run, and the caller treats it as "nothing was split" rather than
            # as "nothing is composite" - a splitter that cannot answer must not read as one that
            # answered no.
            print(json.dumps({"ok": False, "why": "stdin does not parse: %s" % exc}))
            return 2
        heads = known_heads(req.get("names") or [])
        done = set(str(x).strip().lower() for x in (req.get("resolved") or []))
        parts = {}
        for t in (req.get("terms") or []):
            got = split_composite(t, heads, resolved_whole=str(t).strip().lower() in done)
            if got:
                parts[t] = got
        print(json.dumps({"ok": True, "heads": len(heads), "parts": parts}, ensure_ascii=False))
        return 0
    if not args.spec or not args.source:
        print("coverage_check: BLOCKED - --spec and --source are both required")
        return 2

    # Exit 2 is could-not-run, and could-not-look is never a clean bill. A missing or unparseable input
    # must never leave a caller reading "no findings".
    docs = {}
    for label, path in (("spec", args.spec), ("source", args.source)):
        if not os.path.exists(path):
            print(f"coverage_check: BLOCKED - no {label} at {path}")
            return 2
        try:
            with open(path, encoding="utf-8-sig") as fh:
                docs[label] = json.load(fh)
        except Exception as exc:                                    # noqa: BLE001 - any parse failure blocks
            print(f"coverage_check: BLOCKED - the {label} at {path} does not parse: {exc}")
            return 2
    spec, source = docs["spec"], docs["source"]

    if args.battery:
        slug = spec.get("slug") or os.path.splitext(os.path.basename(args.spec))[0]
        rep = battery(spec, source, slug=slug, spec_path=args.spec, source_path=args.source)
        out = args.out
        if not out:
            out = (os.path.join(args.run_dir, "qa", slug + ".battery.json") if args.run_dir
                   else os.path.join(os.path.dirname(os.path.abspath(args.spec)), slug + ".battery.json"))
        os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
        with io.open(out, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(rep, indent=2, ensure_ascii=False))
        if args.json:
            print(json.dumps(rep, indent=2, ensure_ascii=False))
        else:
            for c in rep["checks"]:
                mark = "ok " if c["verdict"] == "pass" else "X  "
                print(f"  {mark} {c['check']:<22} {c['detail']}")
            print("")
            print(f"  report -> {out}")
            print(f"  still needs the QA agent: {', '.join(rep['not_checked'])}")
        print(f"QA-BATTERY-COMPLETE slug={rep['slug']} checks={rep['summary']['checks']} "
              f"failed={rep['summary']['failed']}")
        return 0 if rep["summary"]["failed"] == 0 else 1

    r = coverage(spec, source)
    if args.json:
        print(json.dumps(r, indent=2, ensure_ascii=False))
    else:
        print(f"\n  spec {r['spec_ingredients']} ingredients, source "
              f"{r['source_ingredients']}, matched {r['matched']}")
        for f in r["findings"]:
            print(f"    {f['detail']}")
        print(f"\n  COVERAGE: {r['verdict'].upper()}")
        print(f"  still needs a reviewer: {', '.join(r['not_checked'])}")
    return 0 if r["verdict"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
