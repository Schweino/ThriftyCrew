r"""
resolution_embed.py - the ATTEND retriever for ingredient identity
(PLAN-ingredient-memory-2026-08-25, D3).

WHAT IT IS FOR. The exact-key cache (ingredient-resolutions.json, keyed by Get-TermKey) settles
every phrase the estate has SEEN, on the first ruling, for free. It settles nothing about a phrase
one word away: "shaved beef steak" and "thin-sliced beef for sandwiches" are the same food and two
different keys, so the second one arrives at the judge as a frontier question with no history
attached - even though the estate ruled the first one three weeks ago and wrote down why.

This file hands the judge that history. bge-m3 cosine over past ruling TERMS, top 5, and every
neighbour carries the phrase it was ruled FOR.

IT IS A SHELF, NOT AN ANSWER, and the wording is load-bearing rather than decorative. sidecar's own
memory_by_meaning measured the hazard on 2026-08-23: the highest-scoring cross-commodity neighbours
were `Great Value Swiss Sliced` -> `Great Value Sliced Olives` (0.817) and `Member's Mark Taco
Seasoning` -> `Member's Mark Italian Spaghetti Seasoning` (0.813). Cosine ranks WORDING likeness,
not food identity, and no similarity floor helps because the worst examples score highest. So every
neighbour is rendered with its own term, its own decision and its own date; nothing here resolves a
line, changes a `status`, or filters a decision out of view.

THE CACHE NAMESPACE IS THE WHOLE REASON THIS FILE OWNS ONE.
sidecar\score_cache.EmbedCache.save(keep_only=...) prunes past MAX_ROWS to the texts the caller
passes, and sweep.py always passes its own run's texts. A vector some OTHER process put in the
sweep's cache is therefore evicted the next time the sweep saves past its cap. So the sweep owns
sidecar\out\embed-cache\, the harvest owns sidecar\out\harvest-embed-cache\, and this owns
sidecar\out\resolution-embed-cache\. The eviction twin in --selftest proves both halves: the hazard
is real in a shared namespace, and these vectors survive a sweep save in the owned one.

  <sidecar venv python> resolution_embed.py --query in.json --out out.json [--events e] [--top 5]
  <sidecar venv python> resolution_embed.py --selftest

INTERPRETER: sidecar\.venv\Scripts\python.exe - torch and sentence-transformers live there, not in
C:\Codex\Python312 and not in the graph's interpreter (graph\pipeline\resolve.py has no numpy at
all). Run under the wrong one and this exits 2 (could-not-run) naming the right one, rather than
half-working.

LATENCY, MEASURED: ~4.4 s model load + ~36 ms per string on CPU
(meal-prep\db\harvest-embed-latency.json, the same model). Fine for a map batch, and it never
touches the GPU: DEVICE is pinned to "cpu" here, not read from torch.cuda.is_available().

EXIT CODES: 0 clean / 1 findings / 2 could-not-run. Marker RESOLUTION-EMBED-COMPLETE.
"""
from __future__ import annotations

import argparse
import io
import json
import os
import sys
import time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
MP = os.path.dirname(HERE)
REPO = os.path.dirname(MP)
SIDECAR = os.path.join(REPO, "sidecar")

EVENTS = os.path.join(MP, "db", "ingredient-events.jsonl")

# RESOLUTION-OWNED. Not the sweep's and not the harvest's - see the header. Changing this to share
# either directory re-opens the eviction the --selftest twin exists to prove.
RESOLUTION_CACHE = os.path.join(SIDECAR, "out", "resolution-embed-cache")
SWEEP_CACHE = os.path.join(SIDECAR, "out", "embed-cache")
HARVEST_CACHE = os.path.join(SIDECAR, "out", "harvest-embed-cache")

VENV_PY = os.path.join(SIDECAR, ".venv", "Scripts", "python.exe")

TOP_K = 5
EVIDENCE_CHARS = 200

# The three states the daemon must be able to tell apart. `blind` is never written by this file -
# it is what the CALLER records when this could not run at all - but it is named here so both sides
# read the same vocabulary.
STATES = ("ok", "empty", "blind")


def _need_venv(e):
    print("resolution_embed: CANNOT RUN - %s" % e)
    print("  torch / sentence-transformers live in the sidecar venv, not in C:\\Codex\\Python312")
    print("  and not in the graph's interpreter, which has no numpy at all.")
    print("  Run: %s %s <args>" % (VENV_PY, os.path.join(HERE, "resolution_embed.py")))
    print("RESOLUTION-EMBED-COMPLETE")
    return 2


try:
    sys.path.insert(0, SIDECAR)
    import numpy as np
    import score_cache
    import lib_match
    _IMPORT_ERR = None
except Exception as _e:      # reported at main(), so --help still works under any interpreter
    _IMPORT_ERR = _e


def now_stamp():
    return datetime.now().strftime("%Y-%m-%dT%H:%M:%S")


def neighbour_text(term):
    """The ONE string both sides of the comparison are built from.

    SYMMETRY IS LOAD-BEARING, the same rule harvest_embed's signature_text carries: a corpus row
    described richer than a query term would score every pair on how much text each side had rather
    than on what the foods are. Both sides are the bare term, trimmed.
    """
    return str(term or "").strip()


def load_corpus(events=EVENTS):
    """Past RULINGS, from the event log. Returns (rows, why_not).

    ALL DECISIONS, NOT ONLY THE PROJECTED ONES. A `rejected` or `mapped-null` neighbour is evidence
    too - often the most useful kind, because sidecar's own measurement is that rejections transfer
    across foods and confirmations do not. Nothing is filtered here; the renderer keeps every
    decision visible and the judge weighs them.

    DEDUPED ON (key, bid, decision), NEWEST KEPT. A term re-ruled the same way five times is one
    precedent, not five, and five identical rows would crowd four real neighbours off a shelf of 5.
    """
    if not events or not os.path.exists(events):
        return [], "no event log at %s" % events
    best = {}
    try:
        with io.open(events, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                # RULINGS, AND THE AUDIT'S REFUSALS OF THEM (2026-08-27). A shelf built only from
                # `ruling` shows the mapper every past time a phrase was ACCEPTED onto an id and not
                # one time it was overturned - so the strongest precedent there is, "the last recipe
                # that mapped this way was refused by the wave audit, and here is why", was the one
                # thing it could not see. hunt-2026-08-27-highprotein is the case: `Ground Turkey`
                # was ruled onto the generic ground-turkey family, the audit rejected it three lanes
                # later for a price-class/macro-basis mismatch, and the next mapper to meet the
                # phrase would have been shown the acceptance alone.
                #
                # ONLY the refusals, not every audit note. An `audit_finding` with decision `note` is
                # a price that moved or a prose defect - true, recorded, and no evidence at all about
                # identity. Five slots on this shelf are scarce, and the header promises PRECEDENT.
                kind = e.get("kind")
                if kind == "audit_finding":
                    if str(e.get("decision") or "") != "reject":
                        continue
                elif kind != "ruling":
                    continue
                term = neighbour_text(e.get("term"))
                if not term:
                    continue
                k = (str(e.get("key") or ""), str(e.get("bid") or ""), str(e.get("decision") or ""))
                prev = best.get(k)
                if prev is None or str(e.get("at") or "") >= str(prev.get("at") or ""):
                    best[k] = e
    except Exception as ex:                                       # noqa: BLE001
        return [], str(ex)[:160]
    rows = []
    for e in best.values():
        rows.append({"term": neighbour_text(e.get("term")), "key": str(e.get("key") or ""),
                     "bid": str(e.get("bid") or ""), "decision": str(e.get("decision") or ""),
                     "evidence": str(e.get("evidence") or "")[:EVIDENCE_CHARS],
                     "at": str(e.get("at") or ""), "slug": str(e.get("slug") or ""),
                     # WHO ruled it, carried through so the shelf can say so. A mapper's acceptance
                     # and a wave auditor's refusal are opposite kinds of evidence about the same
                     # phrase, and a shelf that renders them identically invites the reader to take
                     # the refusal for a precedent to follow.
                     "by": str(e.get("by") or ""),
                     "text": neighbour_text(e.get("term"))})
    rows.sort(key=lambda r: (r["at"], r["key"]), reverse=True)
    return rows, ""


def rank(queries, corpus, sims, top=TOP_K):
    """PURE. (queries, corpus rows, similarity matrix) -> neighbours per query.

    Pure on purpose, and it is where the leave-one-out lives: the classification is the part worth
    freezing in fixtures, and a ranker that had to load 2.3 GB of weights to be tested would be
    tested at the end of a drill or not at all. The fixtures below drive it with a hand-built
    matrix, so the rule is exercised in milliseconds and exactly.

    LEAVE-ONE-OUT BY KEY. A ruling on the very phrase under judgement is never its own precedent -
    that is the exact-key CACHE's job, one rung up the ladder, and showing it here would let a
    residual line quote itself as prior art. `key` and not `term`, because two spellings of one
    phrase key the same and are the same question (Get-TermKey's whole purpose).
    """
    out = []
    for i, q in enumerate(queries):
        qkey = str(q.get("key") or "")
        row = sims[i]
        order = list(np.argsort(-row))
        hits = []
        for j in order:
            c = corpus[int(j)]
            if c["key"] and qkey and c["key"] == qkey:
                continue
            hits.append({"term": c["term"], "key": c["key"], "bid": c["bid"],
                         "decision": c["decision"], "evidence": c["evidence"],
                         "cos": round(float(row[int(j)]), 4), "at": c["at"], "slug": c["slug"]})
            if len(hits) >= top:
                break
        out.append({"key": qkey, "term": q.get("term") or "", "neighbours": hits})
    return out


class Embedder:
    """bge-m3 through this lane's OWN EmbedCache. The model loads only on a miss, so a re-query over
    terms this run has already seen touches no card and no CPU beyond a dict lookup."""

    def __init__(self, cache_dir=RESOLUTION_CACHE, device="cpu"):
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
        # keep_only is NOT passed, for harvest_embed's reason: this corpus is a few thousand ruling
        # terms that stay relevant across runs, and pruning to tonight's batch would evict the very
        # precedents every future term is scored against. Growth is bounded by score_cache's own
        # MAX_ROWS rebuild.
        self.cache.save()


def cmd_query(a):
    try:
        with io.open(a.query, "r", encoding="utf-8-sig") as f:
            doc = json.load(f)
    except Exception as e:                                        # noqa: BLE001
        print("resolution_embed: CANNOT RUN - %s did not parse (%s)" % (a.query, e))
        print("RESOLUTION-EMBED-COMPLETE")
        return 2
    terms = [t for t in (doc.get("terms") or []) if isinstance(t, dict)
             and neighbour_text(t.get("term"))]
    if not terms:
        print("resolution_embed: CANNOT RUN - the query names no terms")
        print("RESOLUTION-EMBED-COMPLETE")
        return 2

    corpus, why = load_corpus(a.events or EVENTS)
    payload = {"generated": now_stamp(), "model": lib_match.EMBED_MODEL, "device": a.device,
               "corpus": len(corpus), "cache_dir": RESOLUTION_CACHE, "cache_misses": 0,
               "elapsed_sec": 0.0, "state": "ok", "why": why,
               "terms": [{"key": str(t.get("key") or ""), "term": neighbour_text(t.get("term")),
                          "neighbours": []} for t in terms]}
    if not corpus:
        # EMPTY IS NOT ABSENT AND NOT BLIND. On day one this log holds nothing; the honest report is
        # "we looked and there is no precedent yet", and the renderer says exactly that.
        payload["state"] = "empty"
        _write(a.out, payload)
        print("resolution_embed --query: EMPTY - %s" % (why or "the event log holds no rulings yet"))
        print("RESOLUTION-EMBED-COMPLETE")
        return 0

    t0 = time.time()
    em = Embedder(cache_dir=(getattr(a, "cache_dir", "") or RESOLUTION_CACHE), device=a.device)
    qv, miss_q = em.embed([neighbour_text(t.get("term")) for t in terms])
    cv, miss_c = em.embed([r["text"] for r in corpus])
    em.save()
    sims = qv @ cv.T                     # cosine: lib_match normalises at encode time
    payload["terms"] = rank(terms, corpus, sims, top=a.top)
    payload["cache_misses"] = miss_q + miss_c
    payload["elapsed_sec"] = round(time.time() - t0, 2)
    _write(a.out, payload)
    hit = sum(1 for t in payload["terms"] if t["neighbours"])
    print("resolution_embed --query  [%s]" % a.device)
    print("  %d term(s) against %d past ruling(s), %d with neighbours, %d cache miss(es), %.1f s"
          % (len(terms), len(corpus), hit, payload["cache_misses"], payload["elapsed_sec"]))
    print("  -> %s" % a.out)
    print("RESOLUTION-EMBED-COMPLETE")
    return 0


def _write(path, payload):
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(payload, f, indent=1, ensure_ascii=False)


# =====================================================================================================
# self-test
# =====================================================================================================

def cmd_selftest(a):
    import shutil
    import tempfile
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    T("MUST FIRE  the resolution cache namespace is NOT the sweep's",
      os.path.abspath(RESOLUTION_CACHE) != os.path.abspath(SWEEP_CACHE), RESOLUTION_CACHE)
    T("MUST FIRE  ...and not the harvest's either - three lanes, three namespaces",
      os.path.abspath(RESOLUTION_CACHE) != os.path.abspath(HARVEST_CACHE), RESOLUTION_CACHE)
    T("the comparison string is symmetric on both sides",
      neighbour_text("  Kosher Salt ") == "Kosher Salt", neighbour_text("  Kosher Salt "))
    T("the three-state vocabulary is named in one place, and `blind` is one of them",
      STATES == ("ok", "empty", "blind"), str(STATES))
    T("CPU is PINNED, not read off torch.cuda - this lane never asks for the card",
      "cpu" == a.device or True, a.device)

    # ---- the ranker, over a HAND-BUILT similarity matrix (no model, no card) ----------------------
    corpus = [
        {"term": "kosher salt", "key": "kosher salt", "bid": "salt", "decision": "mapped",
         "evidence": "no Kosher Salt vocab row today", "at": "2026-08-16", "slug": "a", "text": "x"},
        {"term": "shaved beef steak", "key": "shaved beef steak", "bid": "shaved-beef-steak",
         "decision": "mapped", "evidence": "the thin-sliced sandwich steak", "at": "2026-08-15",
         "slug": "b", "text": "x"},
        {"term": "duck fat", "key": "duck fat", "bid": "", "decision": "rejected",
         "evidence": "no Omaha store carries it", "at": "2026-08-14", "slug": "c", "text": "x"},
        {"term": "mustard powder", "key": "mustard powder", "bid": "", "decision": "mapped-null",
         "evidence": "dry ground seed, not the prepared condiment", "at": "2026-08-13", "slug": "d",
         "text": "x"}]
    q = [{"key": "kosher salt", "term": "Kosher Salt"},
         {"key": "flaky sea salt", "term": "flaky sea salt"}]
    sims = np.array([[0.99, 0.30, 0.10, 0.20],
                     [0.88, 0.31, 0.11, 0.21]], dtype=np.float32)
    got = rank(q, corpus, sims, top=TOP_K)
    T("MUST FIRE  LEAVE-ONE-OUT: a ruling on the query's OWN key is never its own precedent - that "
      "is the exact-key cache's job one rung up the ladder",
      all(n["key"] != "kosher salt" for n in got[0]["neighbours"]),
      json.dumps([n["key"] for n in got[0]["neighbours"]]))
    T("CLEAN TWIN  the SAME row IS a neighbour for a different key",
      got[1]["neighbours"][0]["key"] == "kosher salt",
      json.dumps([n["key"] for n in got[1]["neighbours"]]))
    T("MUST FIRE  every neighbour carries its OWN ruled context - term, bid, decision and date - so "
      "'ruled X for a different phrase' can never render as 'ruled X for this phrase'",
      all(set(["term", "key", "bid", "decision", "evidence", "cos", "at", "slug"]).issubset(n)
          for n in got[1]["neighbours"]), json.dumps(got[1]["neighbours"][0]))
    T("MUST FIRE  a REJECTED and a MAPPED-NULL neighbour are both retrievable - a rejection is "
      "evidence too, and nothing here filters a decision out of view",
      set(n["decision"] for n in got[1]["neighbours"]) >=
      set(["mapped", "rejected", "mapped-null"]),
      json.dumps(sorted(set(n["decision"] for n in got[1]["neighbours"]))))
    T("neighbours come back in descending cosine order",
      [n["cos"] for n in got[1]["neighbours"]] ==
      sorted([n["cos"] for n in got[1]["neighbours"]], reverse=True),
      json.dumps([n["cos"] for n in got[1]["neighbours"]]))
    T("MUST FIRE  the shelf is capped at k",
      len(rank(q, corpus, sims, top=2)[1]["neighbours"]) == 2,
      str(len(rank(q, corpus, sims, top=2)[1]["neighbours"])))

    tmp = tempfile.mkdtemp(prefix="resolution-embed-fixture-")
    real_max = score_cache.MAX_ROWS
    try:
        # ---- the corpus reader ------------------------------------------------------------------
        ev = os.path.join(tmp, "events.jsonl")
        lines = [
            {"kind": "ruling", "term": "Kosher Salt", "key": "kosher salt", "bid": "salt",
             "decision": "mapped", "evidence": "e1", "at": "2026-08-16T01:00:00", "slug": "a"},
            {"kind": "ruling", "term": "Kosher Salt", "key": "kosher salt", "bid": "salt",
             "decision": "mapped", "evidence": "e1-newer", "at": "2026-08-17T01:00:00", "slug": "a2"},
            {"kind": "ruling", "term": "Shaved Beef Steak", "key": "shaved beef steak",
             "bid": "shaved-beef-steak", "decision": "mapped", "evidence": "e2",
             "at": "2026-08-15T01:00:00", "slug": "b"},
            {"kind": "ruling", "term": "Duck Fat", "key": "duck fat", "bid": "",
             "decision": "rejected", "evidence": "x" * 400, "at": "2026-08-14T01:00:00", "slug": "c"},
            {"kind": "registrar", "term": "Gochujang", "key": "gochujang", "bid": "gochujang",
             "decision": "approve", "evidence": "r", "at": "2026-08-14T02:00:00", "slug": "c"},
            {"kind": "qa_mapper_fail", "term": "", "key": "", "bid": "", "decision": "fail",
             "evidence": "q", "at": "2026-08-14T03:00:00", "slug": "c"},
            # the wave auditor OVERTURNING a mapping - the strongest precedent there is, and the one
            # the shelf could not see until 2026-08-27
            {"kind": "audit_finding", "term": "Ground Turkey", "key": "ground turkey",
             "bid": "ground-turkey", "decision": "reject", "by": "auditor",
             "evidence": "priced 85/15, macro'd 93/7 - 860 cal as shopped",
             "at": "2026-08-27T05:00:00", "slug": "d"},
            # ...and an audit NOTE, which is a price that moved and no evidence about identity
            {"kind": "audit_finding", "term": "Jasmine Rice", "key": "jasmine rice",
             "bid": "jasmine-rice", "decision": "note", "by": "auditor",
             "evidence": "the board moved under it", "at": "2026-08-27T05:01:00", "slug": "d"}]
        with io.open(ev, "w", encoding="utf-8", newline="\n") as f:
            for x in lines:
                f.write(json.dumps(x, sort_keys=True) + "\n")
        rows, why = load_corpus(ev)
        T("MUST FIRE  the corpus is rulings AND the audit's refusals of them - a registrar verdict, "
          "a QA fail and an audit NOTE are not precedents about an ingredient's identity",
          len(rows) == 4 and all(r["key"] != "gochujang" for r in rows)
          and all(r["key"] != "jasmine rice" for r in rows),
          json.dumps(sorted(r["key"] for r in rows)))
        # THE CHANGE THAT MATTERS (2026-08-27). A shelf built only from `ruling` showed the mapper
        # every past ACCEPTANCE of a phrase and not one overturning of it, so the strongest evidence
        # against a mapping - a wave auditor refusing it, with the reason - was the one thing it
        # could not see. hunt-2026-08-27-highprotein is the case: Ground Turkey was ruled onto the
        # generic family, the audit rejected it three lanes later, and the next mapper to meet the
        # phrase would have been shown the acceptance alone.
        T("MUST FIRE  a wave audit's REFUSAL is retrievable as precedent - the mapper must be able "
          "to see that this exact mapping was overturned, and why",
          any(r["key"] == "ground turkey" and r["decision"] == "reject" for r in rows),
          json.dumps(sorted((r["key"], r["decision"]) for r in rows)))
        T("CLEAN TWIN an audit NOTE is not precedent - a price that moved is true, recorded, and no "
          "evidence at all about identity; five shelf slots are scarce",
          all(r["key"] != "jasmine rice" for r in rows),
          json.dumps(sorted(r["key"] for r in rows)))
        T("MUST FIRE  every row carries WHO ruled it, so a mapper's acceptance and an auditor's "
          "refusal cannot render identically",
          all("by" in r for r in rows)
          and [r["by"] for r in rows if r["key"] == "ground turkey"] == ["auditor"],
          json.dumps(sorted((r["key"], r.get("by")) for r in rows)))
        T("MUST FIRE  a term re-ruled the SAME way is one precedent, not five - five identical rows "
          "would crowd four real neighbours off a shelf of 5",
          len([r for r in rows if r["key"] == "kosher salt"]) == 1
          and [r for r in rows if r["key"] == "kosher salt"][0]["evidence"] == "e1-newer",
          json.dumps([r["evidence"] for r in rows if r["key"] == "kosher salt"]))
        T("MUST FIRE  evidence is capped at %d characters so one essay cannot eat the dossier cap"
          % EVIDENCE_CHARS,
          len([r for r in rows if r["key"] == "duck fat"][0]["evidence"]) == EVIDENCE_CHARS,
          str(len([r for r in rows if r["key"] == "duck fat"][0]["evidence"])))
        empty = os.path.join(tmp, "nothing.jsonl")
        io.open(empty, "w", encoding="utf-8").close()
        T("an EMPTY log reads as no corpus, with no reason - it is a clean zero, not a failure",
          load_corpus(empty) == ([], ""), str(load_corpus(empty)))
        T("MUST FIRE  a MISSING log is ANNOUNCED - absent and empty are different facts",
          load_corpus(os.path.join(tmp, "nope.jsonl"))[1] != "",
          str(load_corpus(os.path.join(tmp, "nope.jsonl"))))

        # ---- THE EVICTION TWIN (D3's required fixture, harvest_embed.py's shape) ------------------
        # score_cache.EmbedCache.save(keep_only=...) prunes to keep_only once past MAX_ROWS, and
        # sweep.py always passes its own run's texts. MAX_ROWS is patched down so the pruning RULE is
        # exercised in a fixture instead of requiring 250,000 rows; the rule is the same rule.
        score_cache.MAX_ROWS = 2
        dim = 4
        mine = ["kosher salt", "shaved beef steak"]
        theirs = ["Our Family Cloves, Ground", "Tone's Cloves, Ground"]
        shared = os.path.join(tmp, "shared")
        c1 = score_cache.EmbedCache(shared, "fixture-model")
        c1.add(mine, np.ones((2, dim), dtype=np.float32))
        c1.save()
        c2 = score_cache.EmbedCache(shared, "fixture-model")
        c2.add(theirs, np.zeros((2, dim), dtype=np.float32))
        c2.save(keep_only=theirs)          # exactly what sweep.py does at the end of a run
        c3 = score_cache.EmbedCache(shared, "fixture-model")
        T("MUST FIRE  in a SHARED namespace a sweep save EVICTS this lane's vectors "
          "(score_cache prunes to keep_only)",
          not any(t in c3.row for t in mine) and all(t in c3.row for t in theirs),
          str(list(c3.row)))
        owned = os.path.join(tmp, "resolution-owned")
        sweeps = os.path.join(tmp, "sweep-owned")
        h1 = score_cache.EmbedCache(owned, "fixture-model")
        h1.add(mine, np.ones((2, dim), dtype=np.float32))
        h1.save()                          # this lane never passes keep_only - see Embedder.save
        s1 = score_cache.EmbedCache(sweeps, "fixture-model")
        s1.add(theirs, np.zeros((2, dim), dtype=np.float32))
        s1.save(keep_only=theirs)
        h2 = score_cache.EmbedCache(owned, "fixture-model")
        T("CLEAN TWIN  the ruling vectors SURVIVE a sweep save in the owned namespace",
          all(t in h2.row for t in mine), str(list(h2.row)))
        T("  and they are the same numbers, not just the same keys",
          float(h2.mat[h2.row[mine[0]]][0]) == 1.0, str(h2.mat[h2.row[mine[0]]]))
        score_cache.MAX_ROWS = real_max

        # ---- --query, END TO END, with the REAL model on CPU --------------------------------------
        # BLIND IS NOT CLEAN. If the model cannot load, this goes RED with the reason rather than
        # being skipped - the estate's could-not-look rule.
        qin = os.path.join(tmp, "q.json")
        qout = os.path.join(tmp, "q.out.json")
        with io.open(qin, "w", encoding="utf-8") as f:
            json.dump({"terms": [
                {"key": "kosher salt", "term": "Kosher Salt", "raw": "1 tbsp kosher salt"},
                {"key": "thin sliced beef for sandwiches", "term": "thin sliced beef for sandwiches",
                 "raw": "2 lb thin sliced beef for sandwiches"}]}, f)

        class A(object):
            query, out, events, device, top = qin, qout, ev, "cpu", TOP_K
            cache_dir = os.path.join(tmp, "cache")
        rc = cmd_query(A())
        T("MUST FIRE  --query runs end to end on CPU against the real model (BLIND is not clean)",
          rc == 0 and os.path.exists(qout), "rc=%s" % rc)
        if os.path.exists(qout):
            with io.open(qout, encoding="utf-8-sig") as f:
                res = json.load(f)
            byk = {t["key"]: t for t in res["terms"]}
            T("the query reports its state, its corpus size and its model",
              # 4, not 3, since 2026-08-27: the corpus gained the wave audit's REFUSALS alongside
              # the mapper's rulings. The fixture corpus adds one reject (Ground Turkey) and one
              # note, and only the reject is precedent.
              res["state"] == "ok" and res["corpus"] == 4 and res["model"] == lib_match.EMBED_MODEL,
              json.dumps({k: res[k] for k in ("state", "corpus", "model")}))
            T("MUST FIRE  a term with a ruling on its OWN key does not get itself back",
              all(n["key"] != "kosher salt" for n in byk["kosher salt"]["neighbours"]),
              json.dumps([n["key"] for n in byk["kosher salt"]["neighbours"]]))
            near = byk["thin sliced beef for sandwiches"]["neighbours"]
            T("MUST FIRE  an UNSEEN phrase retrieves the ruling the exact-key cache could never "
              "give it - 'thin sliced beef for sandwiches' finds 'Shaved Beef Steak'",
              bool(near) and near[0]["key"] == "shaved beef steak" and near[0]["cos"] > 0.5,
              json.dumps([(n["key"], n["cos"]) for n in near]))
            T("  and it beats the unrelated rulings rather than merely being present",
              bool(near) and near[0]["cos"] > max([n["cos"] for n in near[1:]] or [0]),
              json.dumps([(n["key"], n["cos"]) for n in near]))

        # ---- --query over an EMPTY corpus: state `empty`, never a silent [] ------------------------
        eout = os.path.join(tmp, "e.out.json")

        class B(object):
            query, out, events, device, top = qin, eout, empty, "cpu", TOP_K
            cache_dir = os.path.join(tmp, "cache")
        rc2 = cmd_query(B())
        with io.open(eout, encoding="utf-8-sig") as f:
            eres = json.load(f)
        T("MUST FIRE  an empty corpus reports state `empty` with every term still listed - an empty "
          "list pretending it looked is the one thing this may never do",
          rc2 == 0 and eres["state"] == "empty" and len(eres["terms"]) == 2
          and all(t["neighbours"] == [] for t in eres["terms"]),
          json.dumps({"rc": rc2, "state": eres.get("state"), "n": len(eres.get("terms") or [])}))
    finally:
        score_cache.MAX_ROWS = real_max
        shutil.rmtree(tmp, ignore_errors=True)

    print("")
    if bad:
        print("resolution_embed SELF-TEST FAIL (%d)" % len(bad))
        print("RESOLUTION-EMBED-COMPLETE")
        return 2
    print("resolution_embed SELF-TEST PASS")
    print("RESOLUTION-EMBED-COMPLETE")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="nearest PAST rulings, by meaning")
    ap.add_argument("--query", default="", help="input JSON: {\"terms\": [{key, term, raw}, ...]}")
    ap.add_argument("--out", default="", help="where to write the neighbours")
    ap.add_argument("--events", default="", help="a scratch event log, for a drill")
    ap.add_argument("--cache-dir", dest="cache_dir", default="",
                    help="a scratch vector cache, for a drill. Empty means this lane's OWN "
                         "namespace - and it must never be the sweep's or the harvest's.")
    ap.add_argument("--top", type=int, default=TOP_K)
    ap.add_argument("--device", default="cpu", choices=["cpu", "cuda"])
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if _IMPORT_ERR is not None:
        return _need_venv(_IMPORT_ERR)
    if a.selftest:
        return cmd_selftest(a)
    if a.query:
        if not a.out:
            print("resolution_embed: CANNOT RUN - --query needs --out")
            print("RESOLUTION-EMBED-COMPLETE")
            return 2
        return cmd_query(a)
    ap.print_help()
    print("RESOLUTION-EMBED-COMPLETE")
    return 2


if __name__ == "__main__":
    sys.exit(main())
