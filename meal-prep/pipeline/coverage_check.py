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
    head noun (see _head)."""
    s = unicodedata.normalize("NFKD", str(text or ""))
    s = "".join(c for c in s if not unicodedata.combining(c))
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
    if ah != bh:
        return False
    # Same head, different modifiers ('red onion' vs 'green onion', 'heavy
    # cream' vs 'sour cream'): only pair when the modifier sets do not conflict.
    amod, bmod = aw - {ah}, bw - {bh}
    if amod and bmod and not (amod & bmod):
        return False
    return True


def _names(doc) -> list[str]:
    """Pull ingredient names out of either shape: a transcription (raw/item) or
    a built spec (ingredient/name/item)."""
    if isinstance(doc, dict):
        rows = (doc.get("ingredients") or doc.get("extraction", {}).get("ingredients")
                or doc.get("items") or [])
    else:
        rows = doc or []
    out = []
    for r in rows:
        if isinstance(r, str):
            out.append(r)
        elif isinstance(r, dict):
            out.append(r.get("item") or r.get("ingredient") or r.get("name")
                       or r.get("raw") or "")
    return [o for o in out if o]


def coverage(spec_doc, source_doc) -> dict:
    spec, source = _names(spec_doc), _names(source_doc)
    spec_w = [(n, _key(n)) for n in spec]
    src_w = [(n, _key(n)) for n in source]

    matched_src = set()
    invented = []
    for name, w in spec_w:
        hit = next((i for i, (_, sw) in enumerate(src_w)
                    if i not in matched_src and _pairs(w, sw)), None)
        if hit is None:
            invented.append(name)
        else:
            matched_src.add(hit)
    dropped = [n for i, (n, _) in enumerate(src_w) if i not in matched_src]

    findings = []
    for n in invented:
        findings.append({"check": "ingredient-coverage", "severity": "fail",
                         "detail": f"INVENTED: {n!r} is in the built recipe but "
                                   f"nothing in the source transcription denotes it"})
    for n in dropped:
        findings.append({"check": "ingredient-coverage", "severity": "fail",
                         "detail": f"DROPPED: the source lists {n!r} and the built "
                                   f"recipe has nothing that denotes it"})
    return {
        "spec_ingredients": len(spec), "source_ingredients": len(source),
        "matched": len(matched_src), "invented": invented, "dropped": dropped,
        "verdict": "pass" if not findings else "fail",
        "findings": findings,
        # Said plainly so nobody mistakes a green light here for a full QA pass.
        "not_checked": ["method / technique drift", "deliberate substitutions",
                        "scaling arithmetic", "title", "credit", "prose numbers"],
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Ingredient coverage: spec vs source")
    ap.add_argument("--spec", required=True)
    ap.add_argument("--source", required=True)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    with open(args.spec, encoding="utf-8-sig") as fh:
        spec = json.load(fh)
    with open(args.source, encoding="utf-8-sig") as fh:
        source = json.load(fh)
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
