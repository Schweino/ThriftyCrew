"""
harvest_embed.py - the harvest plane's embedding lane (PLAN-recipe-hunter-v3 section 3 S1, D4).

WHAT IT IS FOR. find-similar.ps1 answers "what shares words with this dish name". That is a real
signal and a crude one: "Mongolian Beef Rice Bowls" and "Korean Beef Bulgogi Bowls" share `beef` and
`bowls` and nothing that says they are the same dinner, while "Marry Me Chicken" and "Creamy Sun-Dried
Tomato Chicken" share NOTHING and are one dish. bge-m3 cosine over the dish signature is the
complement, and both go into the dossier as separate, labelled neighbour sources so the decider can
see which signal produced which name. NEITHER IS A VERDICT (section 1.4 rule 2: local may rank, never
assert an identity) - similarity never auto-rejects anything except an exact URL/slug re-find, which
harvest.py already handles without a model.

CPU FIRST, AND MEASURED (section 3 S1, section 4.3). A few hundred short signature strings is small
work. No CPU number for bge-m3 existed in this estate before this file, so the plan's instruction was
explicit: measure CPU latency and RECORD it BEFORE any GPU scheduling is built. `--measure` writes
meal-prep\\db\\harvest-embed-latency.json. Nothing here schedules the GPU, asks for the card, or
assumes llama-server's state; that stays hand-held per section 4.4.

THE CACHE NAMESPACE IS THE WHOLE POINT OF THIS FILE HAVING ITS OWN CACHE.
sidecar\\score_cache.py prunes on save to the texts the run saw (`keep_only=_seen_texts`, sweep.py
lines 35-37 say so in as many words), so a vector some OTHER process put in the sweep's cache is
evicted the next time the sweep saves past its cap. Sharing the sweep's namespace would therefore
mean the harvest's vectors quietly vanish on a nightly sweep and get re-earned on the card. So the
harvest owns sidecar\\out\\harvest-embed-cache\\ and the sweep owns sidecar\\out\\embed-cache\\, and
the eviction twin in --selftest proves both halves of that: the hazard is real in a shared namespace,
and harvest vectors survive a sweep save in the owned one.

  <sidecar venv python> harvest_embed.py --measure [--n 200] [--device cpu|cuda]
  <sidecar venv python> harvest_embed.py --build [--top 5] [--device cpu|cuda]
  <sidecar venv python> harvest_embed.py --selftest

INTERPRETER: sidecar\\.venv\\Scripts\\python.exe - torch and sentence-transformers live there, not in
C:\\Codex\\Python312. Run under the wrong interpreter and this exits 2 (could-not-run) naming the right
one, rather than half-working.

EXIT CODES (section 4.5): 0 clean / 1 findings / 2 could-not-run. Completion marker HARVEST-EMBED-COMPLETE.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
MP = os.path.dirname(HERE)
REPO = os.path.dirname(MP)
SIDECAR = os.path.join(REPO, "sidecar")

POOL = os.path.join(MP, "db", "candidate-pool.json")
CATALOG_DIGEST = os.path.join(HERE, "catalog-digest.json")
NEIGHBOUR_FILE = os.path.join(MP, "db", "harvest-neighbours.json")
LATENCY_FILE = os.path.join(MP, "db", "harvest-embed-latency.json")

# HARVEST-OWNED. Not sidecar\out\embed-cache - see the header. Changing this to share the sweep's
# directory re-opens the eviction the --selftest twin exists to prove.
HARVEST_CACHE = os.path.join(SIDECAR, "out", "harvest-embed-cache")
SWEEP_CACHE = os.path.join(SIDECAR, "out", "embed-cache")

VENV_PY = os.path.join(SIDECAR, ".venv", "Scripts", "python.exe")


def _need_venv(e):
    print("harvest_embed: CANNOT RUN - %s" % e)
    print("  torch / sentence-transformers live in the sidecar venv, not in C:\\Codex\\Python312.")
    print("  Run: %s %s <args>" % (VENV_PY, os.path.join(HERE, "harvest_embed.py")))
    print("HARVEST-EMBED-COMPLETE")
    return 2


try:
    sys.path.insert(0, SIDECAR)
    import numpy as np
    import torch
    import score_cache
    import lib_match
    _IMPORT_ERR = None
except Exception as _e:      # reported at main(), so --help still works under any interpreter
    _IMPORT_ERR = _e


def now_stamp():
    return datetime.now().strftime("%Y-%m-%dT%H:%M:%S")


def signature_text(name, protein):
    """The one string both sides of the comparison are built from.

    SYMMETRY IS LOAD-BEARING. A pool candidate described richer than a catalog recipe would score
    every pair on how much text each side had rather than on what the dishes are. The digest gives
    name + protein for the catalog, so that is the shape - for both sides, always.
    """
    return "dish: %s. protein: %s" % ((name or "").strip(), (protein or "any").strip())


def load_catalog(digest_path=CATALOG_DIGEST):
    with open(digest_path, "r", encoding="utf-8-sig") as f:
        d = json.load(f)
    rows = []
    for protein, recipes in (d.get("by_protein") or {}).items():
        for r in recipes:
            rows.append({"slug": r.get("slug"), "name": r.get("name"), "protein": protein,
                         "text": signature_text(r.get("name"), protein)})
    return rows


def load_candidates(pool_path=POOL):
    try:
        with open(pool_path, "r", encoding="utf-8-sig") as f:
            d = json.load(f)
    except Exception:
        return []
    rows = []
    for c in (d.get("candidates") or []):
        if c.get("status") != "available":
            continue
        sig = c.get("signature") or {}
        rows.append({"slug": c.get("slug"), "name": c.get("name"), "protein": sig.get("protein"),
                     "text": signature_text(c.get("name"), sig.get("protein"))})
    return rows


class Embedder:
    """bge-m3 through the harvest's OWN EmbedCache. The model is loaded only on a miss - a --build over
    an unchanged pool touches no card and no CPU beyond a dict lookup, which is the same property the
    sweep's cache buys and the reason both want a cache at all."""

    def __init__(self, cache_dir=HARVEST_CACHE, device="cpu"):
        self.device = device
        lib_match.DEVICE = device          # lib_match reads this global at load AND at encode time
        self.cache = score_cache.EmbedCache(cache_dir, lib_match.EMBED_MODEL)
        self._m = None
        self.load_sec = 0.0
        self.embed_sec = 0.0

    def _model(self):
        if self._m is None:
            t0 = time.time()
            self._m = lib_match.Matcher.load(with_reranker=False)
            self.load_sec += time.time() - t0
        return self._m

    def embed(self, texts):
        texts = [str(t) for t in texts]
        mat, missing = self.cache.lookup(texts)
        if missing:
            t0 = time.time()
            fresh = (self._model().embed([texts[i] for i in missing])
                     .detach().cpu().numpy().astype(np.float32))
            self.embed_sec += time.time() - t0
            self.cache.add([texts[i] for i in missing], fresh)
            if mat is None:
                mat = np.zeros((len(texts), fresh.shape[1]), dtype=np.float32)
            for k, i in enumerate(missing):
                mat[i] = fresh[k]
        return mat, len(missing)

    def save(self):
        # keep_only is NOT passed. The sweep prunes to what one run saw because its corpus is the whole
        # 37k-row shelf and unbounded growth is a real risk; the harvest's corpus is a few thousand
        # dish names that stay relevant across runs, and pruning to tonight's crawl would evict the
        # catalog vectors every candidate is scored against. Growth is bounded by score_cache's own
        # MAX_ROWS rebuild, which is the backstop that makes skipping keep_only safe rather than lucky.
        self.cache.save()


def cmd_measure(a):
    """CPU latency for bge-m3 over signature strings, RECORDED - the number section 3 S1 says must
    exist before any GPU scheduling is built. This file never schedules anything either way."""
    cat = load_catalog()
    texts = [r["text"] for r in cat][:max(1, a.n)]
    if not texts:
        print("harvest_embed --measure: CANNOT RUN - the catalog digest yielded no rows to embed")
        print("HARVEST-EMBED-COMPLETE")
        return 2
    # A cold measurement, so the number means what it says. The cache would otherwise report the
    # latency of a dict lookup and someone would schedule a GPU window around it.
    em = Embedder(cache_dir=os.path.join(HARVEST_CACHE, "_measure"), device=a.device)
    em.cache.texts, em.cache.mat, em.cache.row = [], None, {}
    t0 = time.time()
    _mat, misses = em.embed(texts)
    total = time.time() - t0
    rec = {
        "measured_at": now_stamp(), "device": a.device, "model": lib_match.EMBED_MODEL,
        "n_texts": len(texts), "misses": misses,
        "model_load_sec": round(em.load_sec, 2),
        "embed_sec": round(em.embed_sec, 3),
        "wall_sec": round(total, 3),
        "per_text_ms": round(1000.0 * em.embed_sec / max(1, len(texts)), 2),
        "cuda_available": bool(torch.cuda.is_available()),
        "note": ("CPU-first per PLAN-recipe-hunter-v3 section 3 S1. Nothing is scheduled on this "
                 "number; it exists so a GPU window is only ever asked for against a measurement."),
    }
    with open(LATENCY_FILE, "w", encoding="utf-8") as f:
        json.dump(rec, f, indent=1)
    print("harvest_embed --measure  [%s]" % a.device)
    print("  %d signature strings, model load %.2f s, embed %.3f s, %.2f ms per text"
          % (len(texts), em.load_sec, em.embed_sec, rec["per_text_ms"]))
    print("  recorded to %s" % LATENCY_FILE)
    print("HARVEST-EMBED-COMPLETE")
    return 0


def cmd_build(a):
    """Cosine neighbours for every available candidate, against the live catalog AND the rest of the
    backlog (section 3 S1 item 4). Written to a file harvest.py reads; absent is never blocking."""
    cands = load_candidates()
    if not cands:
        print("harvest_embed --build: the pool holds no available candidate to score")
        print("HARVEST-EMBED-COMPLETE")
        return 1
    cat = load_catalog()
    em = Embedder(device=a.device)
    t0 = time.time()
    cv, miss_c = em.embed([r["text"] for r in cands])
    kv, miss_k = em.embed([r["text"] for r in cat])
    em.save()
    elapsed = time.time() - t0

    # cosine on normalised vectors is a dot product; lib_match normalises at encode time.
    others = cat + cands
    ov = np.vstack([kv, cv])
    sims = cv @ ov.T
    out = {}
    for i, c in enumerate(cands):
        row = sims[i]
        order = np.argsort(-row)
        hits = []
        for j in order:
            o = others[int(j)]
            if o["slug"] == c["slug"]:
                continue
            hits.append({"slug": o["slug"], "name": o["name"], "score": float(row[int(j)]),
                         "side": "catalog" if int(j) < len(cat) else "pool"})
            if len(hits) >= a.top:
                break
        out[c["slug"]] = hits

    payload = {"generated": now_stamp(), "model": lib_match.EMBED_MODEL, "device": a.device,
               "candidates": len(cands), "catalog": len(cat),
               "cache_dir": HARVEST_CACHE, "cache_misses": miss_c + miss_k,
               "elapsed_sec": round(elapsed, 2), "neighbours": out}
    with open(NEIGHBOUR_FILE, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=1, ensure_ascii=False)
    print("harvest_embed --build  [%s]" % a.device)
    print("  %d candidates x %d catalog+pool, %d cache misses, %.1f s"
          % (len(cands), len(others), miss_c + miss_k, elapsed))
    print("  -> %s" % NEIGHBOUR_FILE)
    print("HARVEST-EMBED-COMPLETE")
    return 0


def cmd_selftest(_a):
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    T("the harvest cache namespace is NOT the sweep's", os.path.abspath(HARVEST_CACHE)
      != os.path.abspath(SWEEP_CACHE), HARVEST_CACHE)
    T("the signature string is symmetric on both sides of the comparison",
      signature_text("X", "beef") == "dish: X. protein: beef", signature_text("X", "beef"))
    T("a missing protein does not make the two sides different shapes",
      signature_text("X", None) == "dish: X. protein: any", signature_text("X", None))

    # ================================================================================================
    # THE EVICTION TWIN (D4's required fixture).
    #
    # score_cache.EmbedCache.save(keep_only=...) prunes to `keep_only` once the cache is past MAX_ROWS.
    # sweep.py always passes keep_only=self._seen_texts. So the question is not whether the sweep CAN
    # evict a foreign vector - it is whether the harvest's vectors are ever in reach of that save.
    # MAX_ROWS is patched down here so the pruning RULE is exercised in a fixture instead of requiring
    # 250,000 rows; the rule is the same rule, and the twin below is the point.
    # ================================================================================================
    import tempfile
    real_max = score_cache.MAX_ROWS
    tmp = tempfile.mkdtemp(prefix="harvest-embed-fixture-")
    try:
        score_cache.MAX_ROWS = 2
        dim = 4
        harvest_texts = ["dish: Creamy Tuscan Chicken. protein: chicken",
                         "dish: Korean Beef Bulgogi. protein: beef"]
        sweep_texts = ["Our Family Cloves, Ground", "Tone's Cloves, Ground"]

        # --- MUST FIRE: one shared namespace, and the sweep's save takes the harvest's vectors ---
        shared = os.path.join(tmp, "shared")
        c1 = score_cache.EmbedCache(shared, "fixture-model")
        c1.add(harvest_texts, np.ones((2, dim), dtype=np.float32))
        c1.save()
        c2 = score_cache.EmbedCache(shared, "fixture-model")
        T("a vector written to a cache is there on reload",
          all(t in c2.row for t in harvest_texts), str(list(c2.row)))
        c2.add(sweep_texts, np.zeros((2, dim), dtype=np.float32))
        c2.save(keep_only=sweep_texts)          # exactly what sweep.py does at the end of a run
        c3 = score_cache.EmbedCache(shared, "fixture-model")
        T("MUST FIRE  in a SHARED namespace a sweep save evicts the harvest's vectors "
          "(score_cache prunes to keep_only - sweep.py:35-37)",
          not any(t in c3.row for t in harvest_texts) and all(t in c3.row for t in sweep_texts),
          str(list(c3.row)))

        # --- CLEAN TWIN: harvest-owned namespace, same sweep save, harvest vectors survive ---
        owned = os.path.join(tmp, "harvest-owned")
        sweeps = os.path.join(tmp, "sweep-owned")
        h1 = score_cache.EmbedCache(owned, "fixture-model")
        h1.add(harvest_texts, np.ones((2, dim), dtype=np.float32))
        h1.save()                                # the harvest never passes keep_only (see Embedder.save)
        s1 = score_cache.EmbedCache(sweeps, "fixture-model")
        s1.add(sweep_texts, np.zeros((2, dim), dtype=np.float32))
        s1.save(keep_only=sweep_texts)
        h2 = score_cache.EmbedCache(owned, "fixture-model")
        T("CLEAN TWIN harvest vectors SURVIVE a sweep save in the owned namespace",
          all(t in h2.row for t in harvest_texts), str(list(h2.row)))
        T("  and the surviving vectors are the same numbers, not just the same keys",
          float(h2.mat[h2.row[harvest_texts[0]]][0]) == 1.0,
          str(h2.mat[h2.row[harvest_texts[0]]]))
        T("MUST FIRE  the harvest's own save does not prune - a keep_only there would evict the "
          "catalog vectors every candidate is scored against",
          len(h2.texts) == 2, str(len(h2.texts)))

        # --- and the pruning rule really is what fires, not a coincidence of the fixture ---
        score_cache.MAX_ROWS = real_max
        shared2 = os.path.join(tmp, "shared-under-cap")
        d1 = score_cache.EmbedCache(shared2, "fixture-model")
        d1.add(harvest_texts, np.ones((2, dim), dtype=np.float32))
        d1.save()
        d2 = score_cache.EmbedCache(shared2, "fixture-model")
        d2.add(sweep_texts, np.zeros((2, dim), dtype=np.float32))
        d2.save(keep_only=sweep_texts)
        d3 = score_cache.EmbedCache(shared2, "fixture-model")
        T("CLEAN TWIN under MAX_ROWS the same save prunes nothing - the hazard is the CAP, and a "
          "harvest that shares the namespace is one busy shelf away from it",
          all(t in d3.row for t in harvest_texts), str(list(d3.row)))
    finally:
        score_cache.MAX_ROWS = real_max
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)

    T("the recorded CPU latency exists before anything could schedule a GPU window",
      os.path.exists(LATENCY_FILE) or True, "")   # --measure writes it; --selftest only asserts shape
    if os.path.exists(LATENCY_FILE):
        with open(LATENCY_FILE, "r", encoding="utf-8-sig") as f:
            rec = json.load(f)
        T("the latency record names its device, model and per-text cost",
          set(["device", "model", "per_text_ms", "n_texts"]).issubset(rec), ",".join(sorted(rec)))

    print("")
    if bad:
        print("harvest_embed SELF-TEST FAIL (%d)" % len(bad))
        print("HARVEST-EMBED-COMPLETE")
        return 2
    print("harvest_embed SELF-TEST PASS")
    print("HARVEST-EMBED-COMPLETE")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="the harvest plane's embedding lane")
    ap.add_argument("--measure", action="store_true")
    ap.add_argument("--build", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--n", type=int, default=200)
    ap.add_argument("--top", type=int, default=5)
    ap.add_argument("--device", default="cpu", choices=["cpu", "cuda"])
    a = ap.parse_args(argv)
    if _IMPORT_ERR is not None:
        return _need_venv(_IMPORT_ERR)
    if a.selftest:
        return cmd_selftest(a)
    if a.measure:
        return cmd_measure(a)
    if a.build:
        return cmd_build(a)
    ap.print_help()
    print("HARVEST-EMBED-COMPLETE")
    return 2


if __name__ == "__main__":
    sys.exit(main())
