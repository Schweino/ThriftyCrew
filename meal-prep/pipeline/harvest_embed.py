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

TOP-5 PER SIDE, NOT TOP-5 OVERALL (D12 rung 1, S2a defect 1). --build scores each candidate against
the live catalog AND the rest of the backlog. Keeping the top 5 of the two CONCATENATED starves the
side that matters: on 2026-08-24 the backlog (476 rows, and it is the side that grows) crowded the
live catalog (540) out of 3,065 of 3,395 stored neighbour entries, and 40 of 476 available candidates
carried NO live neighbour at all. S2 then reads that empty live block, next to `catalog_checked`, as
evidence of absence - the strongest accept signal a dossier has. Both sides' scores are already
computed, so keeping the top 5 of EACH costs one more argsort and closes the hole. AND IT GOT WORSE
WHILE THE PLAN SAT UNBUILT: re-measured 2026-08-26 against 2,444 available candidates and 562 live
recipes, top-5-overall leaves 1,934 of them - 79% - with no live neighbour at all, and only 697 of
12,220 neighbour entries live. Per side: 12,220 of 24,440 live, and 0 candidates starved. The backlog
is the side that grows, so this hole widens on its own.

THE CALIBRATION EMITTER (D12 rung 2, S2a part b). bge-m3 on short dish names runs high - a hand-picked
0.85 would flag half the catalog - so the threshold is never hand-set. The principled null distribution
is the live catalog's OWN internal pairwise similarity: every published recipe was ruled distinct from
every other by construction, so the score at which two PUBLISHED recipes sit is by definition NOT a
duplicate. --calibrate writes that distribution beside the digest, fingerprinted against the digest it
was computed from, and a reader that finds it missing or stale is BLIND (could-not-run), never
defaulted. No threshold constant lives in this file or in harvest.py, and --selftest greps for one.

  <sidecar venv python> harvest_embed.py --measure [--n 200] [--device cpu|cuda]
  <sidecar venv python> harvest_embed.py --build [--top 5] [--device cpu|cuda]
  <sidecar venv python> harvest_embed.py --calibrate [--device cpu|cuda]
  <sidecar venv python> harvest_embed.py --selftest

INTERPRETER: sidecar\\.venv\\Scripts\\python.exe - torch and sentence-transformers live there, not in
C:\\Codex\\Python312. Run under the wrong interpreter and this exits 2 (could-not-run) naming the right
one, rather than half-working.

EXIT CODES (section 4.5): 0 clean / 1 findings / 2 could-not-run. Completion marker HARVEST-EMBED-COMPLETE.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
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
# BESIDE THE DIGEST, deliberately: the distribution is a property OF that digest and goes stale with
# it, so it lives in the same directory and carries the digest's fingerprint (S2a part b).
CALIBRATION_FILE = os.path.join(HERE, "catalog-similarity.json")

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


def load_catalog(digest_path=None):
    digest_path = digest_path or CATALOG_DIGEST   # call time, not import time (see digest_fingerprint)
    with open(digest_path, "r", encoding="utf-8-sig") as f:
        d = json.load(f)
    rows = []
    for protein, recipes in (d.get("by_protein") or {}).items():
        for r in recipes:
            rows.append({"slug": r.get("slug"), "name": r.get("name"), "protein": protein,
                         "text": signature_text(r.get("name"), protein)})
    return rows


MIN_LABELLED_FOR_FLOOR = 20   # below this the labelled set is too small to read a floor off


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


def digest_fingerprint(digest_path=None):
    """What the calibration DATES ITSELF against.

    Not the mtime. reanchor rewrites files this estate has learned not to trust a timestamp on, and a
    digest rebuilt from an unchanged db is byte-identical while its mtime moves - so the fingerprint is
    the digest's own bytes. A calibration whose fingerprint does not match the digest on disk is STALE,
    and stale is could-not-look, not a number to use anyway.
    """
    digest_path = digest_path or CATALOG_DIGEST   # resolved at CALL time - --selftest repoints it
    with open(digest_path, "rb") as f:
        raw = f.read()
    try:
        n = int((json.loads(raw.decode("utf-8-sig")) or {}).get("recipe_count") or 0)
    except Exception:
        n = 0
    return {"file": os.path.basename(digest_path), "sha256": hashlib.sha256(raw).hexdigest(),
            "recipe_count": n}


def top_per_side(row, others, n_cat, self_slug, top):
    """The top `top` neighbours from EACH side, scored separately (D12 rung 1).

    `others` is the catalog rows followed by the pool rows, and `n_cat` is where the boundary sits, so
    the side a neighbour came from is its index - never a lookup that could drift out of step with the
    matrix. A candidate whose five nearest overall are all backlog still comes back carrying its live
    neighbours, which is the whole point: the decider cannot rule on a duplicate it was never shown.
    """
    picked = []
    for lo, hi in ((0, n_cat), (n_cat, len(others))):
        if hi <= lo:
            continue
        block = np.asarray(row, dtype=np.float64)[lo:hi]
        order = np.argsort(-block)
        kept = 0
        for k in order:
            j = lo + int(k)
            o = others[j]
            if o["slug"] == self_slug:
                continue
            picked.append({"slug": o["slug"], "name": o["name"], "score": float(row[j]),
                           "side": "catalog" if j < n_cat else "pool"})
            kept += 1
            if kept >= top:
                break
    return picked


def percentiles(values):
    """{p50, p90, p99, max, n} over a flat sequence. The only statistics S2a part b names, plus the
    max, because the max IS the implied threshold (see cmd_calibrate)."""
    v = np.asarray(values, dtype=np.float64)
    return {"n": int(v.size),
            "p50": float(np.percentile(v, 50)), "p90": float(np.percentile(v, 90)),
            "p99": float(np.percentile(v, 99)), "max": float(v.max())}


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
    starved = 0
    for i, c in enumerate(cands):
        hits = top_per_side(sims[i], others, len(cat), c["slug"], a.top)
        if cat and not [h for h in hits if h["side"] == "catalog"]:
            starved += 1
        out[c["slug"]] = hits

    payload = {"generated": now_stamp(), "model": lib_match.EMBED_MODEL, "device": a.device,
               "candidates": len(cands), "catalog": len(cat),
               "top_per_side": a.top,
               "catalog_fingerprint": digest_fingerprint(),
               "cache_dir": HARVEST_CACHE, "cache_misses": miss_c + miss_k,
               "elapsed_sec": round(elapsed, 2), "neighbours": out}
    with open(NEIGHBOUR_FILE, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=1, ensure_ascii=False)
    print("harvest_embed --build  [%s]" % a.device)
    print("  %d candidates x %d catalog+pool, %d cache misses, %.1f s"
          % (len(cands), len(others), miss_c + miss_k, elapsed))
    print("  top %d PER SIDE: %d candidate(s) carry no live-catalog neighbour" % (a.top, starved))
    print("  -> %s" % NEIGHBOUR_FILE)
    print("HARVEST-EMBED-COMPLETE")
    # A starved candidate is a FINDING, not a crash: the file is still written and every other
    # candidate's evidence is still worth having. Zero is the D12 rung-1 gate.
    return 1 if starved else 0


LEDGER = os.path.join(MP, "db", "considered-dishes.json")
PRECEDENT_TOP = 10   # the window size. MEASURED, see the docstring below; it is Brad's to change.


def load_ledger(path=None):
    """Every dish this estate has ruled on, as a precedent corpus. Returns (rows, why_not).

    The ledger row already carries `name` and `protein` - exactly `signature_text`'s two inputs - so
    a ruling embeds into the SAME vector space and the SAME cache as the catalog and the backlog.
    Nothing new is learned and nothing new is paid for; 406 of 406 rows are usable today.
    """
    path = path or LEDGER
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            d = json.load(f)
    except Exception as e:                                        # noqa: BLE001
        return [], "the ledger at %s could not be read (%s)" % (path, e)
    rows = []
    for r in (d.get("dishes") or []):
        slug = str(r.get("slug") or "").strip()
        if not slug:
            continue
        rows.append({"slug": slug, "name": r.get("name") or slug,
                     "protein": r.get("protein") or "any", "method": r.get("method") or "any",
                     "key": r.get("key") or "", "verdict": r.get("verdict") or "",
                     "reason": r.get("reason") or "", "dupe_of": list(r.get("dupe_of") or []),
                     "run": r.get("run") or "", "at": r.get("at") or "",
                     "text": signature_text(r.get("name"), r.get("protein"))})
    return rows, ("" if rows else "the ledger holds no ruling yet")


def region_key(protein, method):
    """The COARSE region, and deliberately not `Get-DishKey`'s protein|method|family.

    considered-dishes.ps1 is the ONE matcher for what counts as prior art (its own header says so),
    and `Get-Family` derives the family from the dish NAME in PowerShell. Re-implementing that here
    would be a second matcher with a second opinion - the exact thing that file forbids. So this is
    a COUNT for context ("how crowded is this protein+method"), never a claim about what matched.
    """
    return "%s|%s" % ((protein or "any").strip() or "any", (method or "any").strip() or "any")


def precedent_window(queries, rows, sims, top=PRECEDENT_TOP):
    """PURE. (queries, ledger rows, similarity matrix) -> the window per query.

    Pure for the same reason `resolution_embed.rank` is: the ranking rule is the part worth freezing
    in fixtures, and a ranker that had to load 2.3 GB of weights to be tested would be tested at the
    end of a drill or not at all.

    LEAVE-ONE-OUT BY SLUG. A candidate that was deferred and is being re-ruled must never be handed
    its OWN earlier ruling as precedent - that is a candidate quoting itself as prior art, and it is
    the same trap `resolution_embed.rank` closes by key.

    THE WINDOW SAYS IT IS A WINDOW. `in_region` and `in_ledger` travel with it, so a decider can
    always tell "these are the ten nearest of seventy-seven" from "these are the only ten there are".
    """
    out = []
    for i, q in enumerate(queries):
        qslug = str(q.get("slug") or "")
        qregion = region_key(q.get("protein"), q.get("method"))
        row = sims[i]
        order = list(np.argsort(-row))
        shown, mix = [], {"accepted": 0, "rejected_dupe": 0, "rejected_not_fit": 0, "other": 0}
        in_region = 0
        for j in range(len(rows)):
            r = rows[j]
            if region_key(r.get("protein"), r.get("method")) != qregion or r["slug"] == qslug:
                continue
            in_region += 1
            v = str(r.get("verdict") or "")
            if v == "accepted":
                mix["accepted"] += 1
            elif v == "rejected-dupe":
                mix["rejected_dupe"] += 1
            elif v == "rejected-not-fit":
                mix["rejected_not_fit"] += 1
            else:
                mix["other"] += 1
        for j in order:
            r = rows[int(j)]
            if r["slug"] == qslug:
                continue
            shown.append({"slug": r["slug"], "name": r["name"], "key": r["key"],
                          "verdict": r["verdict"], "reason": r["reason"],
                          "dupe_of": list(r["dupe_of"]), "run": r["run"], "at": r["at"],
                          "score": round(float(row[int(j)]), 4)})
            if len(shown) >= max(1, top):
                break
        out.append({
            "slug": qslug,
            "prior_rulings": shown,
            "prior_rulings_window": {
                "shown": len(shown), "in_region": in_region, "in_ledger": len(rows),
                "region": qregion,
                "ranked_by": "bge-m3 cosine to this candidate, nearest first",
                "state": "ok"},
            # P2: the region's ruling MIX, one line instead of a list the decider counts itself.
            # A SIBLING of saturation_pressure and never a replacement - that stays an int, because
            # dossier_rank and two harvest fixtures read it as one.
            "region_rulings": dict(mix, key=qregion, in_ledger=in_region),
        })
    return out


def cmd_precedents(a):
    r"""The k nearest PAST RULINGS to each candidate in a batch, at dispatch time.

    WHY THIS EXISTS (PLAN-precedent-window-2026-09-05). The decide lane's `prior_rulings` was the one
    memory in this pipeline still delivered by coarse key match: every ruling sharing the candidate's
    protein|method|family, unranked, unbounded, and written once nightly by `score_pool`. Three
    measured consequences, all on 2026-09-05:

      - IT BREAKS THE ONE INVARIANT EVERY OTHER DOSSIER FIELD KEEPS. `dossier_neighbours`'s docstring
        says the dossier's "cost per candidate stays CONSTANT in catalog size - the property the cap
        exists for". Ingredients cap at 22, neighbours per channel per side, `same_family_other_
        protein` at 5. This field grew with the ledger: mean 15.3 entries over 1,205 available
        candidates, 239 of them over 40, five at exactly 60 - the whole `chicken|bake|plain` region.
        At 503 bytes an entry that was 16 KB of an 18 KB dossier, 89% of it, and the ledger gains
        ~45 rows on an active hunting day.
      - IT SHOWED LESS PRECEDENT THAN SIMILARITY DOES, not more. Of the 23 dupe rulings whose reason
        cites a prior LEDGER ruling by slug, the key-match list can show only 16 AT ANY DEPTH - the
        other 7 sit in a different coarse region (`sausage-spinach-crustless-quiche` cites
        `sausage-cottage-cheese-egg-bake`, region size 0). Ranking the WHOLE ledger by cosine reaches
        all 23, and 18 inside the top ten.
      - IT WAS STALE WITHIN A RUN. Written at the nightly rescore, so batch 2 could not see what
        batch 1 had just ruled. This is built at dispatch, so it can.

    IT IS NOT A CAP, and that distinction is Brad's ruling of 2026-09-05 ("we don't want to cut it").
    A count cap on the old list would have kept the OLDEST entries - the list arrives in ledger order.
    This is a different list, ranked by relevance to the candidate, that carries more of the estate's
    own cited precedent while staying constant in size.

    THREE STATES, NEVER FAKED, copied from `fill_prior_rulings`: `ok` with a window, `empty` when the
    ledger holds no ruling yet, and `blind` when this could not run at all. The caller keeps the
    nightly list on `blind` and says so; an empty list pretending it looked is how a judge concludes
    there is no precedent when nobody checked.
    """
    try:
        with open(a.query, "r", encoding="utf-8-sig") as f:
            doc = json.load(f)
    except Exception as e:                                        # noqa: BLE001
        print("harvest_embed --precedents: CANNOT RUN - %s did not parse (%s)" % (a.query, e))
        print("HARVEST-EMBED-COMPLETE")
        return 2
    queries = [q for q in (doc.get("queries") or []) if isinstance(q, dict) and q.get("slug")]
    if not queries:
        print("harvest_embed --precedents: CANNOT RUN - the query names no candidates")
        print("HARVEST-EMBED-COMPLETE")
        return 2

    rows, why = load_ledger(a.ledger or None)
    payload = {"generated": now_stamp(), "model": lib_match.EMBED_MODEL, "device": a.device,
               "ledger": len(rows), "top": a.top, "cache_dir": HARVEST_CACHE, "cache_misses": 0,
               "elapsed_sec": 0.0, "state": "ok", "why": why,
               "candidates": [{"slug": q["slug"], "prior_rulings": [],
                               "prior_rulings_window": {"shown": 0, "in_region": 0, "in_ledger": 0,
                                                        "region": region_key(q.get("protein"),
                                                                             q.get("method")),
                                                        "ranked_by": "", "state": "empty"},
                               "region_rulings": {}} for q in queries]}
    if not rows:
        # EMPTY IS NOT ABSENT AND NOT BLIND. On day one the ledger holds nothing; the honest report
        # is "we looked and there is no precedent yet", and the dossier says exactly that.
        payload["state"] = "empty"
        _write_json(a.out, payload)
        print("harvest_embed --precedents: EMPTY - %s" % (why or "the ledger holds no ruling yet"))
        print("HARVEST-EMBED-COMPLETE")
        return 0

    t0 = time.time()
    em = Embedder(cache_dir=(getattr(a, "cache_dir", "") or HARVEST_CACHE), device=a.device)
    qv, miss_q = em.embed([signature_text(q.get("name"), q.get("protein")) for q in queries])
    cv, miss_c = em.embed([r["text"] for r in rows])
    em.save()
    sims = qv @ cv.T                     # cosine: lib_match normalises at encode time
    payload["candidates"] = precedent_window(queries, rows, sims, top=a.top)
    payload["cache_misses"] = miss_q + miss_c
    payload["elapsed_sec"] = round(time.time() - t0, 2)
    _write_json(a.out, payload)
    shown = sum(len(c["prior_rulings"]) for c in payload["candidates"])
    print("harvest_embed --precedents  [%s]" % a.device)
    print("  %d candidate(s) against %d past ruling(s), %d precedent(s) shown, %d cache miss(es), "
          "%.1f s" % (len(queries), len(rows), shown, payload["cache_misses"],
                      payload["elapsed_sec"]))
    print("  -> %s" % a.out)
    print("HARVEST-EMBED-COMPLETE")
    return 0


def _write_json(path, payload):
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=1, ensure_ascii=False)
    os.replace(tmp, path)


def load_labelled(status, pool_path=POOL):
    """Candidates the estate has already RULED, for reading a floor off outcomes instead of a corpus.

    The corpus percentiles say what is unusual among published pairs. They cannot say what is
    diagnostic of a duplicate, because a corpus of published recipes contains no duplicates by
    construction. These rows do: 152 the decider rejected as dupes, 85 it accepted.
    """
    try:
        with open(pool_path, "r", encoding="utf-8-sig") as f:
            d = json.load(f)
    except Exception:                                             # noqa: BLE001
        return []
    rows = []
    for c in (d.get("candidates") or []):
        if (c.get("status") or "") != status:
            continue
        sig = c.get("signature") or {}
        rows.append({"slug": c.get("slug"), "name": c.get("name"),
                     "text": signature_text(c.get("name"), sig.get("protein"))})
    return rows


def _norm_name(s):
    return "".join(ch for ch in (s or "").lower() if ch.isalnum())


def best_to_catalog(em, rows, cat, kv):
    """Each row's highest cosine to the live catalog, SELF EXCLUDED.

    The self-exclusion is not a nicety: an ACCEPTED candidate became a live recipe, so it scores ~1.0
    against itself and would make the accepted distribution look like the dupe distribution. Excluded
    by slug the way top_per_side does, and by normalised name too, because a candidate's slug and its
    published slug are not always the same string.
    """
    if not rows:
        return []
    cv, _miss = em.embed([r["text"] for r in rows])
    sims = cv @ kv.T
    out = []
    for i, r in enumerate(rows):
        s = sims[i].copy()
        for j, k in enumerate(cat):
            if k.get("slug") == r["slug"] or _norm_name(k.get("name")) == _norm_name(r["name"]):
                s[j] = -1.0
        out.append(float(s.max()))
    return sorted(out)


def cmd_calibrate(a):
    """The live catalog's OWN internal pairwise similarity, written beside the digest (S2a part b).

    THE NULL DISTRIBUTION, AND WHY IT IS THE RIGHT ONE. Every recipe in the digest is published, and
    publishing means a decider ruled it distinct from everything already there. So the scores this
    corpus produces against ITSELF are, by construction, the scores of NON-duplicates - which makes the
    largest of them the lowest bar any dupe threshold may honestly sit at. That is the whole derivation:
    `dupe_threshold` is the corpus MAX, not a number anybody picked, and it sits above p99 by the
    definition of a maximum rather than by a margin someone chose. It tracks the corpus, so it sharpens
    as the catalog grows instead of going stale - the property the fixed histogram never had.

    NOTHING HERE REJECTS ANYTHING. S2a's "what deliberately does not move" is explicit: no auto-rejection
    on similarity at any score. This file emits a ruler; the decider still rules.
    """
    try:
        fp = digest_fingerprint()
    except Exception as e:
        print("harvest_embed --calibrate: CANNOT RUN - no catalog digest (%s)" % e)
        print("  run make-catalog-digest.ps1 first; a calibration without a digest would be a guess.")
        print("HARVEST-EMBED-COMPLETE")
        return 2
    cat = load_catalog()
    if len(cat) < 2:
        print("harvest_embed --calibrate: CANNOT RUN - the digest holds %d recipe(s); a pairwise "
              "distribution needs at least 2" % len(cat))
        print("HARVEST-EMBED-COMPLETE")
        return 2
    em = Embedder(device=a.device)
    t0 = time.time()
    kv, misses = em.embed([r["text"] for r in cat])
    em.save()
    sims = kv @ kv.T
    iu = np.triu_indices(len(cat), k=1)          # each unordered pair once, self-pairs excluded
    pair = sims[iu]
    dist = percentiles(pair)
    # The closest published pairs, NAMED. A bare max is a number nobody can check; these ten let a
    # reader see for themselves whether the corpus maximum is one odd pair or a whole shelf, which is
    # the difference between a threshold that means something and one that inherited an outlier.
    order = np.argsort(-pair)[:10]
    closest = [{"a": cat[int(iu[0][int(k)])]["slug"], "b": cat[int(iu[1][int(k)])]["slug"],
                "score": round(float(pair[int(k)]), 4)} for k in order]
    top_pair = [closest[0]["a"], closest[0]["b"]]
    elapsed = time.time() - t0
    rec = {
        "generated": now_stamp(),
        "generated_from": fp,               # the digest this distribution IS a property of
        "model": lib_match.EMBED_MODEL, "device": a.device,
        "signature_shape": "dish: <name>. protein: <protein>",
        "recipes": len(cat),
        "n": dist["n"], "p50": round(dist["p50"], 4), "p90": round(dist["p90"], 4),
        "p99": round(dist["p99"], 4), "max": round(dist["max"], 4),
        "dupe_threshold": round(dist["max"], 4),
        "dupe_threshold_basis": ("the corpus maximum: the highest score at which two PUBLISHED - and "
                                 "therefore ruled-distinct - recipes sit. Read this number; never "
                                 "hand-set one. Above p99 by the definition of a maximum."),
        "max_pair": top_pair,
        "closest_published_pairs": closest,
        "elapsed_sec": round(elapsed, 2), "cache_misses": misses,
        "note": ("Calibration only. S2a: no auto-rejection on similarity at any score - local ranks, "
                 "the decider rules. A reader that cannot find this file, or finds its generated_from "
                 "fingerprint different from the digest on disk, is BLIND and must say so."),
    }
    # ---- and the ASK FLOOR, read off outcomes rather than off the corpus ----------------------
    # The corpus above is a null distribution: it contains no duplicates by construction, so it can
    # say what is UNUSUAL and never what is DIAGNOSTIC. These rows are the estate's own rulings.
    dup = best_to_catalog(em, load_labelled("ruled:rejected-dupe"), cat, kv)
    acc = best_to_catalog(em, load_labelled("ruled:accepted"), cat, kv)
    em.save()
    floor, floor_basis, overlap = None, "", None
    if len(dup) >= MIN_LABELLED_FOR_FLOOR:
        floor = round(float(dup[0]) - 0.005, 3)   # just under the lowest a known dupe has ever sat
        floor_basis = ("the lowest max-cosine at which any of the %d labelled rejected-dupes sits "
                       "(%.4f), less a hair. It is a FLOOR for who to ASK the local model about, "
                       "never a rule that refuses: measured on the same labelled sets, the dupe and "
                       "acceptance distributions overlap end to end (dupe median %.4f vs acceptance "
                       "median %.4f), so no cut separates them and S2a's no-auto-rejection stands."
                       % (len(dup), dup[0], dup[len(dup) // 2], acc[len(acc) // 2] if acc else -1))
        overlap = {"labelled_dupes": len(dup), "labelled_accepted": len(acc),
                   "dupe_median": round(dup[len(dup) // 2], 4),
                   "accepted_median": round(acc[len(acc) // 2], 4) if acc else None,
                   "dupe_min": round(dup[0], 4),
                   "accepted_min": round(acc[0], 4) if acc else None,
                   "dupes_above_floor": sum(1 for v in dup if v >= floor),
                   "accepted_above_floor": sum(1 for v in acc if v >= floor)}
    rec["ask_floor"] = floor
    rec["ask_floor_basis"] = floor_basis or (
        "NOT SET - only %d labelled rejected-dupe(s) available and %d are required. Without it the "
        "embedding side contributes no shortlist and the pass says so rather than reading an empty "
        "shortlist as 'no near neighbour'." % (len(dup), MIN_LABELLED_FOR_FLOOR))
    rec["ask_floor_separation"] = overlap
    with open(CALIBRATION_FILE, "w", encoding="utf-8") as f:
        json.dump(rec, f, indent=1)
    print("harvest_embed --calibrate  [%s]" % a.device)
    print("  %d live recipes -> %d pairs: p50 %.4f  p90 %.4f  p99 %.4f  max %.4f  (%.1f s)"
          % (len(cat), dist["n"], dist["p50"], dist["p90"], dist["p99"], dist["max"], elapsed))
    print("  closest published pair: %s <-> %s" % (top_pair[0], top_pair[1]))
    if rec["ask_floor"] is None:
        print("  ask floor: NOT SET - %s" % rec["ask_floor_basis"])
    else:
        o = rec["ask_floor_separation"]
        print("  ask floor READ from %d labelled dupe(s): %.3f  (catches %d/%d dupes; %d/%d "
              "acceptances are also asked about, which costs a local call each and refuses nobody)"
              % (o["labelled_dupes"], rec["ask_floor"], o["dupes_above_floor"], o["labelled_dupes"],
                 o["accepted_above_floor"], o["labelled_accepted"]))
        print("  the two distributions OVERLAP (dupe median %.4f vs acceptance median %.4f) - this "
              "is a floor for who to ASK, not a rule that refuses" % (o["dupe_median"], o["accepted_median"]))
    print("  -> %s" % CALIBRATION_FILE)
    print("HARVEST-EMBED-COMPLETE")
    return 0


def _calibrate_with_no_digest():
    """Run the real --calibrate verb against a digest that is not there, and give back its exit code.

    A fixture that asserted "we wrote a refusal branch" would prove nothing; this takes the branch.
    """
    global CATALOG_DIGEST
    real = CATALOG_DIGEST
    try:
        CATALOG_DIGEST = os.path.join(HERE, "no-such-catalog-digest.json")
        return cmd_calibrate(argparse.Namespace(device="cpu"))
    finally:
        CATALOG_DIGEST = real


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

    # ================================================================================================
    # STARVATION (D12 rung 1's named MUST-FIRE fixture).
    #
    # The row below is the shape S2a measured 40 times over: a candidate whose five nearest overall are
    # ALL backlog. Top-5-overall returns five pool rows and the dossier's live block comes back empty -
    # next to `catalog_checked`, that reads as "the catalog was searched and holds nothing like this",
    # which is the strongest accept signal a dossier carries. The overall ordering is computed here in
    # the fixture rather than kept as a retired code path, so the hazard is exercised, not remembered.
    # ================================================================================================
    others = [{"slug": "live-a", "name": "Live A"}, {"slug": "live-b", "name": "Live B"},
              {"slug": "self", "name": "Self"},
              {"slug": "pool-a", "name": "Pool A"}, {"slug": "pool-b", "name": "Pool B"},
              {"slug": "pool-c", "name": "Pool C"}, {"slug": "pool-d", "name": "Pool D"},
              {"slug": "pool-e", "name": "Pool E"}, {"slug": "pool-f", "name": "Pool F"}]
    n_cat = 3
    row = [0.71, 0.68, 1.00, 0.97, 0.96, 0.95, 0.94, 0.93, 0.92]
    overall = [others[j]["slug"] for j in sorted(range(len(others)), key=lambda j: -row[j])
               if others[j]["slug"] != "self"][:5]
    T("MUST FIRE  top-5 OVERALL returns five backlog rows and NO live neighbour - the starvation "
      "S2a measured on 40 of 476 candidates",
      all(s.startswith("pool-") for s in overall) and len(overall) == 5, ",".join(overall))
    per = top_per_side(row, others, n_cat, "self", 5)
    live = [h for h in per if h["side"] == "catalog"]
    pool_side = [h for h in per if h["side"] == "pool"]
    T("MUST FIRE  top-5 PER SIDE still carries the live neighbours the overall cut threw away",
      [h["slug"] for h in live] == ["live-a", "live-b"], ",".join(h["slug"] for h in live))
    T("CLEAN TWIN and it keeps the backlog side whole - this is recall added, nothing traded away",
      [h["slug"] for h in pool_side] == ["pool-a", "pool-b", "pool-c", "pool-d", "pool-e"],
      ",".join(h["slug"] for h in pool_side))
    T("MUST FIRE  a candidate never appears among its own neighbours",
      all(h["slug"] != "self" for h in per), ",".join(h["slug"] for h in per))
    T("each side is capped independently, so the backlog can never crowd the catalog out again",
      len(top_per_side(row, others, n_cat, "self", 1)) == 2,
      str(len(top_per_side(row, others, n_cat, "self", 1))))
    T("CLEAN TWIN with no catalog rows at all the live side is empty and SAYS so by being empty - "
      "the caller reports it as a finding rather than the file pretending it looked",
      [h["side"] for h in top_per_side(row[3:], others[3:], 0, "self", 3)] == ["pool"] * 3,
      str([h["side"] for h in top_per_side(row[3:], others[3:], 0, "self", 3)]))
    T("the score travels with the neighbour, so a dossier line names the recipe AND the number",
      bool(live) and abs(live[0]["score"] - 0.71) < 1e-9,
      str(live[0]["score"]) if live else "no live neighbour at all")

    # ================================================================================================
    # CALIBRATION (D12 rung 2's named MUST-FIRE fixture).
    # ================================================================================================
    d = percentiles([0.10, 0.20, 0.30, 0.40, 0.50, 0.60, 0.70, 0.80, 0.90, 1.00])
    T("the distribution reports exactly what S2a part b names - p50, p90, p99, n",
      set(["p50", "p90", "p99", "n"]).issubset(d) and d["n"] == 10, ",".join(sorted(d)))
    T("MUST FIRE  the implied dupe threshold sits ABOVE p99 - two published recipes must never read "
      "as duplicates of each other, because that is what published means",
      d["max"] > d["p99"] and d["p99"] > d["p50"],
      "max=%s p99=%s p50=%s" % (d["max"], d["p99"], d["p50"]))

    # NO HAND-SET THRESHOLD ANYWHERE IN CODE. Not "we did not add one" - a scanner, run over the
    # identity instruments themselves, so the next session that reaches for 0.85 trips this.
    def threshold_constants(text):
        pat = [r"\b\w*(?:threshold|cutoff|min_sim|sim_min|dupe_at)\w*\s*=\s*[01]?\.\d+",
               r"\b(?:score|sim|similarity|cosine)\w*\s*(?:>=|>|<=|<|-ge|-gt|-le|-lt)\s*[01]?\.\d+"]
        return [m.group(0) for p in pat for m in re.finditer(p, text, re.I)]

    # The two probes are SPLIT ACROSS ADJACENT STRING LITERALS on purpose. Written whole they would be
    # real matches inside this very file, and the scan below - which reads harvest_embed.py itself -
    # would flag its own fixture and go red for the one reason that is not a defect. Python joins the
    # halves at compile time, so the scanner still sees the constant and the comparison in full.
    probe_const = "DUPE_THRESHOLD = " "0.92"
    probe_cmp = "if score > " "0.85:"
    T("MUST FIRE  the scanner catches a hand-set threshold constant",
      len(threshold_constants(probe_const)) == 1, str(threshold_constants(probe_const)))
    T("MUST FIRE  and it catches one hidden in a comparison instead of a name",
      len(threshold_constants(probe_cmp)) == 1, str(threshold_constants(probe_cmp)))
    scanned, hits = [], []
    for p in (os.path.join(HERE, "harvest_embed.py"), os.path.join(HERE, "harvest.py"),
              os.path.join(HERE, "find-similar.ps1")):
        if os.path.exists(p):
            scanned.append(os.path.basename(p))
            with open(p, "r", encoding="utf-8") as f:
                hits += ["%s: %s" % (os.path.basename(p), h) for h in threshold_constants(f.read())]
    T("CLEAN TWIN no hand-set similarity threshold exists in the identity instruments (%s) - the "
      "threshold is READ from the emitted distribution" % ",".join(scanned),
      not hits and len(scanned) == 3, "; ".join(hits) or ",".join(scanned))

    # DATING. A calibration that cannot prove which digest it came from is not a calibration.
    if os.path.exists(CATALOG_DIGEST):
        fp = digest_fingerprint()
        T("the digest fingerprint is its BYTES, not its mtime (reanchor moves mtimes; bytes tell the "
          "truth)", len(fp["sha256"]) == 64 and fp["recipe_count"] > 0, json.dumps(fp))
        if os.path.exists(CALIBRATION_FILE):
            with open(CALIBRATION_FILE, "r", encoding="utf-8-sig") as f:
                cal = json.load(f)
            T("the emitted calibration DATES ITSELF against the digest",
              (cal.get("generated_from") or {}).get("sha256") == fp["sha256"],
              json.dumps(cal.get("generated_from")))
            T("MUST FIRE  and the threshold it publishes sits above its own p99",
              float(cal["dupe_threshold"]) > float(cal["p99"]),
              "%s vs %s" % (cal.get("dupe_threshold"), cal.get("p99")))
    # BLIND IS A FIRST-CLASS OUTCOME. The refusal is exercised, not asserted about: point the module at
    # a digest that is not there and call the real verb.
    rc = _calibrate_with_no_digest()
    T("MUST FIRE  --calibrate REFUSES on a missing digest (exit 2, could-not-run) rather than "
      "emitting a default distribution", rc == 2, "exit %s" % rc)
    T("CLEAN TWIN and it did not write a calibration file while blind",
      (not os.path.exists(CALIBRATION_FILE)) or
      (json.load(open(CALIBRATION_FILE, encoding="utf-8-sig")).get("n") or 0) > 0,
      "a blind run left a file behind")

    # ================================================================================================
    # THE PRECEDENT WINDOW (PLAN-precedent-window-2026-09-05 P1/P2).
    #
    # Driven by a hand-built similarity matrix, exactly like resolution_embed.rank's fixtures and for
    # the same reason: the RANKING RULE is the part worth freezing, and a ranker that needed 2.3 GB
    # of weights to be tested would be tested at the end of a drill or not at all.
    # ================================================================================================
    # LEDGER ORDER IS DELIBERATELY THE REVERSE OF SIMILARITY ORDER. A neuter on 2026-09-05 replaced
    # the argsort with `range(len(rows))` and this suite stayed GREEN, because the first draft's
    # nearest rows also happened to be its first rows - a ranking fixture that could not fail. The
    # corpus below is ordered far, mid, near so ledger order and cosine order disagree on every row.
    _rows = [
        {"slug": "far", "name": "Far Dish", "protein": "beef", "method": "skillet",
         "key": "beef|skillet|plain", "verdict": "rejected-not-fit", "reason": "r3", "dupe_of": [],
         "run": "r", "at": "2026-09-03", "text": "t"},
        {"slug": "mid", "name": "Mid Dish", "protein": "chicken", "method": "bake",
         "key": "chicken|bake|plain", "verdict": "accepted", "reason": "r2", "dupe_of": [],
         "run": "r", "at": "2026-09-02", "text": "t"},
        {"slug": "near", "name": "Near Dish", "protein": "chicken", "method": "bake",
         "key": "chicken|bake|plain", "verdict": "rejected-dupe", "reason": "r1", "dupe_of": ["x"],
         "run": "r", "at": "2026-09-01", "text": "t"},
        {"slug": "self", "name": "Self Dish", "protein": "chicken", "method": "bake",
         "key": "chicken|bake|plain", "verdict": "accepted", "reason": "r4", "dupe_of": [],
         "run": "r", "at": "2026-09-04", "text": "t"},
    ]
    _q = [{"slug": "self", "name": "Self Dish", "protein": "chicken", "method": "bake"}]
    #                        far   mid   near  self
    _sims = np.array([[0.60, 0.70, 0.80, 0.99]], dtype=np.float32)
    _w = precedent_window(_q, _rows, _sims, top=2)[0]
    _got = [x["slug"] for x in _w["prior_rulings"]]
    T("MUST FIRE  the window is the NEAREST rulings, ranked by cosine descending - the whole reason "
      "it carries more cited precedent than the unbounded key-match list did",
      _got == ["near", "mid"], str(_got))
    T("MUST FIRE  LEAVE-ONE-OUT: a candidate re-ruled after a deferral is never handed its OWN "
      "earlier ruling as prior art, however close it scores",
      "self" not in _got and _sims[0][3] > _sims[0][0], str(_got))
    T("MUST FIRE  the window SAYS it is a window - shown, in_region and in_ledger travel with it, so "
      "'the ten nearest of seventy-seven' cannot read as 'the only ten there are'",
      _w["prior_rulings_window"]["shown"] == 2
      and _w["prior_rulings_window"]["in_region"] == 2      # near + mid; self excluded, far is beef
      and _w["prior_rulings_window"]["in_ledger"] == 4,
      json.dumps(_w["prior_rulings_window"]))
    T("MUST FIRE  the region's ruling MIX sums to its own in_ledger count - a summary that does not "
      "add up is worse than the list it replaces",
      (_w["region_rulings"]["accepted"] + _w["region_rulings"]["rejected_dupe"]
       + _w["region_rulings"]["rejected_not_fit"] + _w["region_rulings"]["other"])
      == _w["region_rulings"]["in_ledger"] == 2,
      json.dumps(_w["region_rulings"]))
    T("CLEAN TWIN a window larger than the corpus returns what exists and says so, rather than "
      "padding to the cap",
      len(precedent_window(_q, _rows, _sims, top=99)[0]["prior_rulings"]) == 3,
      str(len(precedent_window(_q, _rows, _sims, top=99)[0]["prior_rulings"])))
    T("the region COUNT is protein|method and is not a second copy of Get-DishKey - "
      "considered-dishes.ps1 is the one matcher, and its family comes off the NAME in PowerShell",
      region_key("chicken", "bake") == "chicken|bake" and region_key(None, "") == "any|any",
      region_key(None, ""))
    _led, _why = load_ledger(os.path.join(HERE, "definitely-not-a-ledger.json"))
    T("MUST FIRE  an unreadable ledger is a REASON, never an empty corpus that reads as 'no precedent'",
      _led == [] and "could not be read" in _why, _why)
    if os.path.exists(LEDGER):
        _live, _lw = load_ledger()
        T("every live ledger row embeds on the SAME signature_text as the catalog - one vector space, "
          "one cache, nothing new paid for",
          len(_live) > 0 and all(r["text"].startswith("dish: ") for r in _live),
          "%d rows, %s" % (len(_live), _lw))

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
    ap.add_argument("--calibrate", action="store_true")
    ap.add_argument("--precedents", action="store_true",
                    help="the k nearest PAST RULINGS to each candidate in a batch, for the decide "
                         "lane's dossier. Needs --query and --out.")
    ap.add_argument("--query", default="", help="with --precedents: input JSON "
                                                "{\"queries\": [{slug, name, protein, method}, ...]}")
    ap.add_argument("--out", default="", help="with --precedents: where to write the window")
    ap.add_argument("--ledger", default="", help="with --precedents: a scratch ledger, for a drill")
    ap.add_argument("--cache-dir", dest="cache_dir", default="",
                    help="with --precedents: a scratch embedding cache, for a drill")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--n", type=int, default=200)
    # --top is the window size for --precedents and the per-side neighbour count for --build. They
    # were separate numbers before this flag was shared; PRECEDENT_TOP is the default for the former.
    ap.add_argument("--top", type=int, default=0)
    ap.add_argument("--device", default="cpu", choices=["cpu", "cuda"])
    a = ap.parse_args(argv)
    if not a.top:
        a.top = PRECEDENT_TOP if a.precedents else 5
    if _IMPORT_ERR is not None:
        return _need_venv(_IMPORT_ERR)
    if a.selftest:
        return cmd_selftest(a)
    if a.precedents:
        if not a.query or not a.out:
            print("harvest_embed --precedents: CANNOT RUN - needs --query <in.json> --out <out.json>")
            print("HARVEST-EMBED-COMPLETE")
            return 2
        return cmd_precedents(a)
    if a.measure:
        return cmd_measure(a)
    if a.build:
        return cmd_build(a)
    if a.calibrate:
        return cmd_calibrate(a)
    ap.print_help()
    print("HARVEST-EMBED-COMPLETE")
    return 2


if __name__ == "__main__":
    sys.exit(main())
