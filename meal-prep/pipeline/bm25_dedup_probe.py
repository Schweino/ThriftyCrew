"""bm25_dedup_probe.py - does a LEXICAL index find duplicate recipes the embedding lane misses?

    python meal-prep/pipeline/bm25_dedup_probe.py

BACKLOG E4. rag-craft's finding is that vector search fails QUIETLY on rare exact identifiers: it
returns plausible irrelevance rather than nothing. The estate's dedup neighbour evidence is bge-m3
cosine over a dish signature and nothing else, and the dedup-selector rules on that evidence. So the
question E4 asks is whether a BM25 index alongside it would surface true duplicates cosine ranks low.

THIS IS A PROBE, NOT A BUILD. It measures on data already on disk and writes nothing but its report.
The backlog calls E4 "a cheap and well-defined experiment" and this is the experiment; whether to build
the hybrid index is a decision to take AFTER reading the number, not before.

GROUND TRUTH is the estate's own rulings, not a hand-made set: a pool candidate with
status == "ruled:rejected-dupe" whose `dupe_of` names a twin that is still live. Those are pairs a
human or the dedup-selector ALREADY judged to be the same dish, which is the only labelled duplicate
data this estate has.

WHAT THIS CANNOT TELL YOU, stated up front because a retrieval number invites over-reading:
  * It measures BM25's recall of KNOWN duplicates. It cannot measure duplicates nobody ever ruled on,
    and those are exactly the ones a better index would be for. A held-out set can only contain
    failures somebody already found.
  * Every pair here was found by the CURRENT pipeline, so the set is biased toward what cosine plus a
    human already catches. BM25 scoring well on it means "it would not have lost these"; BM25 scoring
    badly is the stronger signal, because it would rule the idea out.
  * It compares BM25 against the true twin's rank, not against cosine's rank for the same pair -
    the stored neighbour lists are written at rescore time and are not in this file's inputs.
"""
from __future__ import annotations

import io
import json
import math
import os
import re
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
MP = os.path.normpath(os.path.join(HERE, ".."))
REPO = os.path.normpath(os.path.join(MP, ".."))

STOP = set("""a an the and or of for with without in on to from by at as is are was were be been
this that these those it its into over under more most less least new fresh easy quick best good
recipe recipes make made making style homemade""".split())


def rj(p):
    with io.open(p, encoding="utf-8-sig") as f:
        return json.load(f)


def toks(s):
    """Lower-case word tokens of 3+ chars, stopped. Deliberately plain - a clever tokeniser would make
    this measure the tokeniser rather than the retrieval idea."""
    return [w for w in re.findall(r"[a-z0-9]+", (s or "").lower()) if len(w) >= 3 and w not in STOP]


class BM25(object):
    """Textbook Okapi BM25. Written here rather than pulled in because the pinned interpreter has no
    rank_bm25 and E4 is a question about whether the IDEA pays, not about a package."""

    def __init__(self, docs, k1=1.5, b=0.75):
        self.k1, self.b = k1, b
        self.docs = docs
        self.df = Counter()
        self.tf = []
        self.len = []
        for d in docs:
            c = Counter(d)
            self.tf.append(c)
            self.len.append(len(d))
            for w in c:
                self.df[w] += 1
        self.N = len(docs) or 1
        self.avg = (sum(self.len) / float(self.N)) if self.N else 0.0

    def idf(self, w):
        n = self.df.get(w, 0)
        return math.log(1.0 + (self.N - n + 0.5) / (n + 0.5))

    def score(self, q, i):
        s = 0.0
        tf, dl = self.tf[i], self.len[i]
        for w in q:
            f = tf.get(w, 0)
            if not f:
                continue
            s += self.idf(w) * (f * (self.k1 + 1)) / (f + self.k1 * (1 - self.b + self.b * dl / (self.avg or 1)))
        return s


def head_to_head():
    r"""BM25 versus COSINE on the same labelled pairs, over the same population.

    THIS IS THE MEASUREMENT THAT DECIDES THE BUILD, and the recall number alone could not. A lexical
    index earns its place beside a vector one by finding what the vector one MISSES - not by
    independently finding what it already catches. Ranking BM25 well on pairs cosine also ranks well
    argues for nothing.

    NO MODEL IS LOADED AND THE GPU IS NOT TOUCHED. sidecar\out\harvest-embed-cache holds the bge-m3
    vectors the harvest lane already computed, L2-normalised, so cosine is a dot product. That matters
    beyond speed: harvest-crawl.ps1 carries three MUST-FIRE assertions that it never reaches for the
    card, because section 4.4 gives the GPU to the nightly chain.

    Run it under the SIDECAR interpreter (it has numpy); the pinned one does not.
    """
    import numpy as np                                        # noqa: PLC0415

    cache_idx = os.path.join(REPO, "sidecar", "out", "harvest-embed-cache", "BAAI_bge-m3.index.json")
    cache_vec = os.path.join(REPO, "sidecar", "out", "harvest-embed-cache", "BAAI_bge-m3.npy")
    if not (os.path.isfile(cache_idx) and os.path.isfile(cache_vec)):
        print("HEAD-TO-HEAD COULD NOT EVALUATE: no embedding cache at %s" % cache_idx)
        print("Nothing was compared, so nothing is proven either way.")
        return 3

    keys = rj(cache_idx)
    vecs = np.load(cache_vec)
    at = {}
    for i, k in enumerate(keys):
        at.setdefault(k, i)

    pool = rj(os.path.join(MP, "db", "candidate-pool.json"))
    cands = pool.get("candidates") or []

    def cache_key(c):
        """The harvest lane's signature text. Reconstructed, and VERIFIED by hit rate below rather than
        assumed - a key format that silently stopped matching would leave this reporting on two pairs
        and calling it a result."""
        prot = ""
        s = c.get("signature")
        if isinstance(s, dict) and s.get("protein"):
            prot = str(s["protein"])
        return "dish: %s. protein: %s" % (c.get("name") or "", prot)

    by_slug = {}
    for c in cands:
        if c.get("slug"):
            by_slug.setdefault(c["slug"], c)

    twin = {}
    try:
        ledger = rj(os.path.join(MP, "db", "considered-dishes.json"))
        for r in (ledger.get("dishes") or []):
            if r.get("verdict") == "rejected-dupe" and r.get("dupe_of"):
                twin[r.get("slug")] = list(r["dupe_of"])
    except Exception:                                          # noqa: BLE001
        pass

    pairs = []
    for c in cands:
        if c.get("status") != "ruled:rejected-dupe":
            continue
        tw = c.get("dupe_of") or twin.get(c.get("slug")) or []
        for s in tw:
            b = by_slug.get(s)
            if b is None:
                continue
            ka, kb = cache_key(c), cache_key(b)
            if ka in at and kb in at and at[ka] != at[kb]:
                pairs.append((c, b, at[ka], at[kb]))
                break

    print("cached vectors      : %d" % len(keys))
    print("labelled pairs BOTH sides of which are in the cache: %d" % len(pairs))
    if not pairs:
        print("")
        print("HEAD-TO-HEAD COULD NOT EVALUATE: no labelled pair has both sides in the embedding cache.")
        print("That is a KEY-FORMAT or COVERAGE failure, not evidence about either index.")
        return 3

    # BM25 over the same population the cosine ranking sees, so the two ranks are comparable.
    texts = [toks(k) for k in keys]
    bm = BM25(texts)

    rows = []
    for c, b, ia, ib in pairs:
        q = texts[ia]
        cos = vecs @ vecs[ia]
        cos[ia] = -2.0
        cr = int((cos > cos[ib]).sum()) + 1
        bs = np.array([bm.score(q, i) for i in range(len(texts))])
        bs[ia] = -1.0
        br = int((bs > bs[ib]).sum()) + 1
        rows.append((c.get("slug"), b.get("slug"), cr, br))

    n = len(rows)
    def hits(idx, k):
        return sum(1 for r in rows if r[idx] <= k)

    print("")
    print("rank of the TRUE twin, same %d pairs, same population:" % n)
    print("             cosine      BM25")
    for k in (1, 5, 10, 25):
        print("  recall@%-3d %4d       %4d" % (k, hits(2, k), hits(3, k)))
    print("  MRR       %6.3f     %6.3f"
          % (sum(1.0 / r[2] for r in rows) / n, sum(1.0 / r[3] for r in rows) / n))

    # THE QUESTION. A pair cosine buries and BM25 surfaces is the case FOR a hybrid; the reverse is the
    # case against. Both are counted, because reporting only the flattering direction is how a
    # measurement becomes an argument.
    bm_saves = [r for r in rows if r[2] > 10 and r[3] <= 10]
    cos_saves = [r for r in rows if r[3] > 10 and r[2] <= 10]
    both_miss = [r for r in rows if r[2] > 10 and r[3] > 10]
    print("")
    print("  BM25 finds in top-10 what cosine does NOT : %d   <- the case FOR a hybrid" % len(bm_saves))
    print("  cosine finds what BM25 does not           : %d" % len(cos_saves))
    print("  neither finds in top-10                   : %d" % len(both_miss))
    for s in bm_saves[:8]:
        print("      %-44s cosine #%-5d BM25 #%d" % (s[0][:44], s[2], s[3]))
    print("")
    print("READ IT THIS WAY. The left column is what the estate has today. A hybrid is worth building")
    print("only if the first count is meaningfully above zero - that is BM25 catching duplicates the")
    print("current evidence buries. If it is zero, BM25 adds a second index and no new information.")
    return 0


def main():
    pool = rj(os.path.join(MP, "db", "candidate-pool.json"))
    cands = pool.get("candidates") or []

    # The corpus is every pool row that is not the candidate being queried: the population a neighbour
    # search actually ranks over.
    def sig_text(c):
        """The signature is a DICT - {protein, method, sauce_family, starch}, frequently all null - so
        it is flattened to its non-null values and joined with the name. A dict fed straight to the
        tokeniser raised TypeError on the first run; worse, if it had stringified silently the corpus
        would have been built from "{'protein': None, ...}" for every row and the probe would have
        measured nothing while producing a number."""
        s = c.get("signature")
        parts = []
        if isinstance(s, dict):
            parts = [str(v) for v in s.values() if v]
        elif s:
            parts = [str(s)]
        if c.get("name"):
            parts.append(str(c["name"]))
        return " ".join(parts)

    rows = [c for c in cands if sig_text(c).strip()]
    text = [toks(sig_text(c)) for c in rows]
    slug_at = {}
    for i, c in enumerate(rows):
        if c.get("slug"):
            slug_at.setdefault(c["slug"], i)

    # ---- ground truth: the estate's own rejected-dupe rulings
    twin = {}
    try:
        ledger = rj(os.path.join(MP, "db", "considered-dishes.json"))
        for r in (ledger.get("dishes") or []):
            if r.get("verdict") == "rejected-dupe" and r.get("dupe_of"):
                twin[r.get("slug")] = list(r["dupe_of"])
    except Exception as e:                                        # noqa: BLE001
        print("considered-dishes.json could not be read (%s) - falling back to pool dupe_of only" % e)

    pairs = []
    for c in cands:
        if c.get("status") != "ruled:rejected-dupe":
            continue
        tw = c.get("dupe_of") or twin.get(c.get("slug")) or []
        a = slug_at.get(c.get("slug"))
        b = next((slug_at[s] for s in tw if s in slug_at), None)
        if a is None or b is None or a == b:
            continue
        pairs.append((a, b))

    print("corpus rows        : %d" % len(rows))
    print("labelled dupe pairs: %d" % len(pairs))
    if not pairs:
        print("")
        print("PROBE COULD NOT EVALUATE: no labelled duplicate pair has BOTH sides present in the pool.")
        print("Nothing was measured, so nothing is proven - this is not evidence that BM25 would not help.")
        return 3
    if len(pairs) < 20:
        print("NOTE: fewer than 20 pairs. Any rate below is a wide interval on a small n and must not")
        print("      be reported as a percentage without it.")

    bm = BM25(text)
    ranks = []
    for a, b in pairs:
        q = text[a]
        if not q:
            continue
        scored = sorted(((bm.score(q, i), i) for i in range(len(rows)) if i != a), reverse=True)
        pos = next((k + 1 for k, (_s, i) in enumerate(scored) if i == b), None)
        ranks.append(pos if pos else len(scored) + 1)

    n = len(ranks)
    def at(k):
        return sum(1 for r in ranks if r <= k)
    mrr = sum(1.0 / r for r in ranks) / n

    print("")
    print("BM25 rank of the TRUE twin, over %d labelled pair(s):" % n)
    for k in (1, 5, 10, 25):
        print("  recall@%-3d %4d / %-4d  (%.1f%%)" % (k, at(k), n, 100.0 * at(k) / n))
    print("  MRR        %.3f" % mrr)
    print("  median rank %d, worst %d" % (sorted(ranks)[n // 2], max(ranks)))
    print("")
    print("READ IT THIS WAY. A HIGH recall@10 means a lexical index would independently find the")
    print("duplicates this estate already knows about - which is the case FOR adding BM25 beside the")
    print("embedding lane, because the two would then have to agree. A LOW one rules the idea out")
    print("cheaply. Neither number says anything about duplicates nobody ever ruled on, and those are")
    print("the ones a better index would actually be for.")
    return 0


def selftest():
    """Prove the BM25 arithmetic before believing any number it produces.

    A scorer nobody checked, reporting a recall a decision rests on, is the shape this estate keeps
    writing guards about. These are properties of Okapi BM25, not of the recipe data.
    """
    fails = []

    def T(name, cond, got=""):
        if cond:
            print("  ok    %s" % name)
        else:
            print("  X     %s   got: %s" % (name, got))
            fails.append(name)

    docs = [toks("chicken tikka masala rice"),
            toks("chicken tikka masala rice"),
            toks("beef stroganoff noodles"),
            toks("chicken noodle soup")]
    bm = BM25(docs)
    q = docs[0]
    ranked = sorted(range(len(docs)), key=lambda i: -bm.score(q, i))
    T("MUST FIRE  an exact duplicate outranks an unrelated dish", ranked[0] in (0, 1), str(ranked))
    T("MUST FIRE  a document sharing NO term scores exactly zero",
      bm.score(toks("zzz qqq"), 2) == 0.0, bm.score(toks("zzz qqq"), 2))

    # THE PROPERTY E4 IS ABOUT. A term in ONE document must outweigh a term in every document -
    # that rare-identifier sensitivity is precisely what rag-craft says vector search loses.
    rare = BM25([toks("chicken sumac rice"), toks("chicken beef rice"), toks("chicken pork rice")])
    T("MUST FIRE  a RARE term carries more idf than a term in every document",
      rare.idf("sumac") > rare.idf("chicken"), "%.3f vs %.3f" % (rare.idf("sumac"), rare.idf("chicken")))

    T("CLEAN TWIN the tokeniser drops stopwords and short tokens",
      toks("The BEST of a chicken") == ["chicken"], toks("The BEST of a chicken"))
    T("CLEAN TWIN an empty corpus does not divide by zero", BM25([]).avg == 0.0, BM25([]).avg)

    if fails:
        print("SELF-TEST FAIL: %d case(s)" % len(fails))
        return 1
    print("SELF-TEST PASS: exact-duplicate ranking, zero-overlap scoring, rare-term idf, tokenising, empty corpus")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    if "--head-to-head" in sys.argv:
        sys.exit(head_to_head())
    sys.exit(main())
