"""THE DEDUP PROMPT DRILL, part 1 of 2: build the labelled pair sets WITH ingredients.

WHY THIS IS COMMITTED AND NOT SCRATCH. It produced the numbers in
`design\\EVAL-dedup-shortlist-2026-09-04.md` section 8, on which Brad retired the ingest refusal
path (P1c). A measurement whose inputs cannot be reconstructed is an anecdote, and the specific
thing worth re-reading before trusting section 8 is `norm_line` below: both sides of every pair are
reduced to WHAT FOOD IT IS, and if that reduction is unfair to one side the recall figures move.

Set 1 - POSITIVES: pool `ruled:rejected-dupe` candidates joined to their ledger twin by slug. Needs
        `harvest.py --reingredients-ruled` to have run, or they carry no lines.
Set 2 - NEGATIVES: the N hardest PUBLISHED pairs by bge-m3 cosine. Both members live, both ruled
        distinct by a decider, so any `same` here is a recipe the estate would have thrown away.
        CAVEAT, and it is in the EVAL too: they are not all clean negatives - see
        `design\\OPEN-ITEM-published-near-duplicates-2026-09-04.md`.

Needs the SIDECAR venv (torch) for set 2 only; the pinned interpreter has none. Writes pairs.json
beside itself. Reads only; writes nothing into the pool, the ledger or any recipe.

    sidecar\\.venv\\Scripts\\python.exe meal-prep\\pipeline\\dedup_prompt_drill_pairs.py [N=300]
"""
import json, io, os, re, sys, html as _html

REPO = r"C:\Codex\ThriftyCrew"
MP = os.path.join(REPO, "meal-prep")
PIPE = os.path.join(MP, "pipeline")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pairs.json")
HARD_N = int(sys.argv[1]) if len(sys.argv) > 1 else 300


def rj(p):
    with io.open(p, encoding="utf-8-sig") as f:
        return json.load(f)


QTY = re.compile(r"^\s*[\d\u00bc-\u00be/.,\-\u2013\s]*"
                 r"(?:ounces?|oz|pounds?|lbs?|lb|cups?|tablespoons?|tbsp|teaspoons?|tsp|"
                 r"cloves?|cans?|grams?|g|kg|ml|quarts?|pints?|packages?|pkg|slices?|"
                 r"large|small|medium|whole)?\s*", re.I)


def norm_line(s):
    """A line reduced to WHAT FOOD IT IS. Both sides get the same treatment or the comparison is
    scoring how much text each side had - the symmetry lesson from signature_text."""
    s = _html.unescape(re.sub(r"<[^>]+>", " ", str(s)))
    s = s.split(":")[0] if "</strong>" in str(s) or "**" in str(s) else s
    s = re.sub(r"\([^)]*\)", " ", s)          # brands and gram weights
    s = QTY.sub("", s, count=1)
    s = re.sub(r",.*$", "", s)                 # "onion, diced" -> "onion"
    s = re.sub(r"\s+", " ", s).strip(" .,-").lower()
    return s


def live_lines(path):
    d = rj(path)
    out = []
    for x in (d.get("ingredients_display") or []):
        m = re.sub(r"<[^>]+>", "", str(x))
        name = m.split(":")[0]
        n = norm_line(name)
        if n:
            out.append(n)
    return d, out


def dedupe(xs, cap=14):
    seen, out = set(), []
    for x in xs:
        if x and x not in seen:
            seen.add(x)
            out.append(x)
    return out[:cap]


recipes_dir = os.path.join(MP, "db", "recipes")
live = {}
for fn in os.listdir(recipes_dir):
    if not fn.endswith(".json"):
        continue
    try:
        d, lines = live_lines(os.path.join(recipes_dir, fn))
    except Exception:
        continue
    live[d.get("slug") or fn[:-5]] = {"slug": d.get("slug") or fn[:-5], "name": d.get("name") or "",
                                      "protein": d.get("protein") or "any",
                                      "lines": dedupe(lines)}
print("live recipes with ingredients: %d" % len(live))

# ---- set 1: the labelled positives -----------------------------------------------------------
pool = rj(os.path.join(MP, "db", "candidate-pool.json"))
ledger = rj(os.path.join(MP, "db", "considered-dishes.json"))
twin = {}
for row in (ledger.get("dishes") or []):
    if row.get("verdict") == "rejected-dupe" and row.get("dupe_of"):
        twin[row.get("slug")] = list(row["dupe_of"])

pos, why_not = [], {"no-ledger-twin": 0, "twin-not-live": 0, "no-cand-lines": 0}
for c in pool.get("candidates") or []:
    if c.get("status") != "ruled:rejected-dupe":
        continue
    t = c.get("dupe_of") or twin.get(c.get("slug")) or []
    if not t:
        why_not["no-ledger-twin"] += 1
        continue
    hit = next((live[s] for s in t if s in live), None)
    if hit is None:
        why_not["twin-not-live"] += 1
        continue
    lines = dedupe([norm_line(x) for x in (c.get("ingredients_verbatim") or [])])
    if not lines:
        why_not["no-cand-lines"] += 1
        continue
    pos.append({"kind": "positive",
                "a": {"slug": c["slug"], "name": c.get("name") or "", "lines": lines},
                "b": {"slug": hit["slug"], "name": hit["name"], "lines": hit["lines"]}})
print("labelled positives joinable: %d  (%s)" % (len(pos), why_not))

# ---- set 2: the hardest published pairs -------------------------------------------------------
neg = []
try:
    sys.path.insert(0, os.path.join(REPO, "sidecar"))
    sys.path.insert(0, PIPE)
    import numpy as np
    import harvest_embed as he
    cat = [r for r in he.load_catalog() if r.get("slug") in live]
    em = he.Embedder(device="cpu")
    mat, _miss = em.embed([r["text"] for r in cat])
    em.save()
    sims = mat @ mat.T
    n = len(cat)
    idx = [(float(sims[i][j]), i, j) for i in range(n) for j in range(i + 1, n)]
    idx.sort(key=lambda t: -t[0])
    for score, i, j in idx[:HARD_N]:
        a, b = live[cat[i]["slug"]], live[cat[j]["slug"]]
        neg.append({"kind": "negative", "score": round(score, 4),
                    "a": {"slug": a["slug"], "name": a["name"], "lines": a["lines"]},
                    "b": {"slug": b["slug"], "name": b["name"], "lines": b["lines"]}})
    print("hardest published pairs: %d  score %.4f - %.4f"
          % (len(neg), neg[-1]["score"], neg[0]["score"]))
except Exception as e:
    print("NEGATIVES NOT BUILT - %s: %s" % (type(e).__name__, e))

with io.open(OUT, "w", encoding="utf-8") as f:
    json.dump({"positives": pos, "negatives": neg}, f, indent=1, ensure_ascii=False)
print("-> %s" % OUT)
