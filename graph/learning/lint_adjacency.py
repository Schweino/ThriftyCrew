"""Find the exclude patterns that DON'T fire because English put a word in the way.

    python graph/learning/lint_adjacency.py                 # everything, ranked
    python graph/learning/lint_adjacency.py --live-only     # only what a shopper can see
    python graph/learning/lint_adjacency.py --commodity milk

THE BUG CLASS THIS EXISTS FOR. Four wrong prices shipped in two days, all the
same shape - an exclude written as two adjacent words, defeated by a name that
separates them or pluralises one:

    ground-cloves   excluded  \\bwhole\\s+clove\\b     name said "Whole Cloves"
                    -> $11.92/oz published for a jar of cloves worth $2.99

    milk            excluded  chocolate\\s+milk        name said "Milk, Lowfat,
                    1% Milkfat, Chocolate" - four tokens apart
                    -> plain milk swallowed the cheap chocolate gallon

    oranges         excluded  \\bjuice\\b              name said "Oj"

    beef-jerky      excluded  \\bfor\\s+dogs?\\b AND \\bdog\\b AND
                    dog\\s+(food|treats?) - name said "Jerky Treats for All
                    Dogs". TEN pet patterns, not one fired.
                    -> a DOG TREAT was crowned the cheapest beef jerky in Omaha

None of these were exotic. They are what happens when a pattern is written the
way a person would say it and then meets the way a marketing department writes
it. Fixing them one at a time as each wrong price surfaces is not a strategy -
this looks for the rest of them before a shopper does.

WHAT IT CHECKS, both against the REAL corpus (every product name the engine
reads, not a subset - see FINDINGS #10):

  GAP     a multi-word exclude like `chocolate\\s+milk` that misses names where
          those words appear within a few tokens of each other. Reported only
          when the commodity CURRENTLY CLAIMS the name - i.e. the exclude was
          written for that product and is failing at its one job.

  NUMBER  an exclude whose literal word appears in the corpus only in a form the
          pattern cannot match - `\\bdog\\b` against "Dogs". Same test: only
          reported where the commodity actually claims the name.

A finding is NOT automatically a bug. `\\bfor\\s+dogs?\\b` failing on "Hot Dogs"
would be correct behaviour. Every hit needs reading, and the ones touching a
LIVE board cell need reading first - which is what the ranking is for.

IT PROPOSES NOTHING AND WRITES NOTHING. Widening a pattern re-homes products
(FINDINGS #11), so the fix is a judgement call with its own blast radius, made
per case. This only says where to look.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

from graphdb import REPO_ROOT                              # noqa: E402

GROCERY = os.path.join(REPO_ROOT, "grocery")
CATALOG = os.path.join(GROCERY, "commodities.json")

# Every file set the ENGINE reads. Measuring against out\regular alone missed 17%
# of the corpus and Sam's Club almost entirely - see FINDINGS #10.
CORPUS_GLOBS = [
    r"out\regular\*.json", r"out\sams\*.json", r"out\bakers\*.json",
    r"out\fareway\*.json", r"out\extra\*.json", r"out\ads-*.json",
]


def corpus() -> list[str]:
    names: set[str] = set()
    for pat in CORPUS_GLOBS:
        for f in glob.glob(os.path.join(GROCERY, pat)):
            try:
                with open(f, encoding="utf-8-sig") as fh:
                    doc = json.load(fh)
            except Exception:
                continue
            rows = doc if isinstance(doc, list) else next(
                (doc[k] for k in ("deals", "products", "items", "rows")
                 if isinstance(doc.get(k), list)), [])
            for r in rows:
                if not isinstance(r, dict):
                    continue
                for k in ("item", "name", "product", "title"):
                    if r.get(k):
                        names.add(str(r[k]))
                        break
    return sorted(names)


def live_cells() -> dict[str, set[str]]:
    """commodity -> {lowercased product names it currently PUBLISHES}."""
    out: dict[str, set[str]] = {}
    files = sorted(glob.glob(os.path.join(GROCERY, "out", "comparison-*.json")))
    if not files:
        return out
    with open(files[-1], encoding="utf-8-sig") as fh:
        for r in json.load(fh)["comparison"]:
            for s in (r.get("stores") or []):
                if s.get("per_unit"):
                    out.setdefault(r["id"], set()).add(str(s.get("item") or "").strip().lower())
    return out


# A literal run of word characters, i.e. something a product name could spell out.
_LITERAL = re.compile(r"^[a-z][a-z'-]*$", re.I)


def literals(pattern: str) -> list[str]:
    """The plain words a pattern insists on, in order, or [] if it is not that shape.

    Deliberately conservative. A pattern with alternation, a character class or a
    quantified group is not one this lint can reason about, and guessing at it
    would produce noise that buries the real findings.
    """
    if re.search(r"[\[\](){}|+*?]", re.sub(r"\\s\+|\\b|s\?|\\\.", "", pattern)):
        return []
    parts = re.split(r"\\s\+|\\s\*|\s+", pattern)
    words = []
    for p in parts:
        w = p.replace(r"\b", "").replace("s?", "").replace(r"\.", "").strip()
        if not w:
            continue
        if not _LITERAL.match(w):
            return []
        # Single letters are noise. `\bd\s+batteries\b` (D-cells) "near-misses" every
        # AA pack in the corpus, because a lone 'd' occurs inside Done, Double, Duracell.
        # Six of the first nineteen live findings were this, and nothing else was.
        if len(w) < 2:
            return []
        words.append(w.lower())
    return words


# A product whose name shouts a DIFFERENT class than the commodity holding it. This is
# the beef-jerky-crowned-a-dog-treat shape, and it is the only near-miss worth waking
# someone for: the others cost a cent, this one publishes pet food as human food.
CLASS_SIGNAL = re.compile(
    r"\bfor\s+(?:\w+\s+){0,3}(?:dogs?|cats?|puppies|kittens)\b|\bcanine\b|\bfeline\b"
    r"|\bpet\s+food\b|\bkibble\b|\bcat\s+litter\b"
    r"|\bdetergent\b|\bdisinfect|\bbleach\b|\bcleaner\b|\bair\s+freshener\b"
    r"|\bliqueur\b|\bvodka\b|\bwhiskey\b|\bbourbon\b|\btequila\b"
    r"|\bsupplements?\b|\bsoftgels?\b|\bmultivitamins?\b"
    r"|\bimitation\b|\bartificially\s+flavou?red\b", re.I)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--live-only", action="store_true",
                    help="only findings on a product the board currently publishes")
    ap.add_argument("--commodity", default="")
    ap.add_argument("--class-risk", action="store_true",
                    help="only near-misses where the product names a DIFFERENT class - pet, household, alcohol, supplement. The dog-treat-as-beef-jerky shape.")
    ap.add_argument("--gap", type=int, default=30, help="chars allowed between words")
    ap.add_argument("--catalog", default="",
                    help="read a different commodities.json; test_gates.py points this at a fixture with a known hole in it to prove the lint FIRES")
    args = ap.parse_args()

    names = corpus()
    low = [(n, n.lower()) for n in names]
    live = live_cells()
    catalog_path = args.catalog or CATALOG
    with open(catalog_path, encoding="utf-8-sig") as fh:
        catalog = [r for r in json.load(fh) if r.get("id")]
    print(f"corpus {len(names)} distinct product names | {len(catalog)} commodities\n")

    findings = []
    for row in catalog:
        cid = row["id"]
        if args.commodity and cid != args.commodity:
            continue
        try:
            inc = [re.compile(p, re.I) for p in (row.get("include") or [])]
            exc_raw = list(row.get("exclude") or [])
            exc = [re.compile(p, re.I) for p in exc_raw]
        except re.error:
            continue
        if not inc:
            continue
        # What this commodity actually claims today. The lint only cares about
        # excludes failing on products the commodity HOLDS - an exclude that
        # misses something the commodity never wanted is not a defect.
        claimed = [(n, ln) for n, ln in low
                   if any(p.search(ln) for p in inc) and not any(p.search(ln) for p in exc)]
        if not claimed:
            continue
        pub = live.get(cid, set())

        for raw in exc_raw:
            words = literals(raw)
            if not words:
                continue
            if len(words) >= 2:
                # word1 [plural?] [up to `gap` chars] word2 ... - the pattern the author
                # almost certainly meant, against the one they actually wrote.
                sep = r"s?.{0,%d}?" % args.gap
                loose = re.compile(sep.join(re.escape(w) for w in words) + r"s?", re.I)
                kind = "GAP"
            else:
                # NUMBER: the word appears, but only in a form the pattern misses.
                loose = re.compile(r"\b" + re.escape(words[0]) + r"(?:s|es)\b", re.I)
                kind = "NUMBER"
            for n, ln in claimed:
                if loose.search(ln):
                    findings.append({
                        "commodity": cid, "kind": kind, "pattern": raw,
                        "product": n, "live": ln in pub,
                        "class_risk": bool(CLASS_SIGNAL.search(n)),
                    })

    if args.class_risk:
        findings = [f for f in findings if f["class_risk"]]
    findings.sort(key=lambda f: (not f["live"], not f["class_risk"], f["commodity"]))
    live_n = sum(1 for f in findings if f["live"])
    shown = [f for f in findings if f["live"]] if args.live_only else findings
    print(f"{len(findings)} near-miss(es); {live_n} on a product the board PUBLISHES\n")

    cur = None
    for f in shown:
        if f["commodity"] != cur:
            cur = f["commodity"]
            print(f"== {cur}")
        flag = ("LIVE " if f["live"] else "     ") + ("!CLASS " if f["class_risk"] else "       ")
        print(f"  {flag}{f['kind']:<7}{f['pattern'][:34]:<36}{f['product'][:62]}")

    print("\nA near-miss is a QUESTION, not a bug. Read each one: an exclude failing on a")
    print("product it was never meant to catch is correct behaviour. Start with the LIVE")
    print("rows - those are prices a shopper can see today.")
    print("Widening a pattern re-homes products; measure where they land before fixing.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
