"""
app.py - the local semantic sidecar. FastAPI on 127.0.0.1, called from PowerShell exactly like the
smp-feed Worker is called (Invoke-RestMethod), so it fits the estate's existing habits.

CONTRACT WITH THE ESTATE (these are the rules that make it safe to run unattended)
---------------------------------------------------------------------------------
1. ADVISORY ONLY. Every endpoint returns scores and rankings. Nothing here writes a price, a crown, a
   rule, or a link. Findings flow into the arrivals desk / contested-match / coverage reports where the
   existing adjudication path applies.
2. BLIND, NEVER BLOCK. If this service is down, callers must treat it as could-not-evaluate (the estate's
   exit-3 convention) and publish anyway. The board must never depend on a GPU box being healthy. The
   PowerShell side is responsible for honouring that; /health exists so it can tell the difference
   between "clean" and "did not run", which is the distinction the zero-rows rule exists to protect.
3. LOCALHOST ONLY. Binds 127.0.0.1 and takes no auth, because it must never be reachable off the box.
4. MODELS ARE PINNED. Swapping a model changes every score in the estate, so it is a deliberate,
   fixtured act - see lib_match.EMBED_MODEL / RERANK_MODEL and the drift watch in the design doc.

Run:  .venv\Scripts\python.exe -m uvicorn app:app --host 127.0.0.1 --port 8077
"""
from __future__ import annotations
import os, sys, time
from typing import Sequence

from fastapi import FastAPI
from pydantic import BaseModel, Field

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib_match import Matcher, clean_product, commodity_text, DEVICE, EMBED_MODEL, RERANK_MODEL

app = FastAPI(title="Thrifty Crew semantic sidecar", version="1.0")

# Lazy load: importing the module must not cost 100 s and 3 GB of VRAM. The first real request pays it.
_M: Matcher | None = None
_loaded_at: float | None = None


def matcher() -> Matcher:
    global _M, _loaded_at
    if _M is None:
        t0 = time.time()
        _M = Matcher.load(with_reranker=True)
        _loaded_at = time.time() - t0
    return _M


class EmbedReq(BaseModel):
    texts: list[str]
    clean: bool = Field(True, description="strip trailing pack/size noise before embedding")


class MatchReq(BaseModel):
    products: list[str]
    commodity: dict = Field(..., description="{id,label,exemplars[]} - the SAME shape commodity-defs.json uses")
    rerank: bool = True


class ScoreReq(BaseModel):
    pairs: list[list[str]] = Field(..., description="[[product, commodity_text], ...]")


@app.get("/health")
def health() -> dict:
    """Cheap and side-effect free. Callers use this to decide clean-vs-BLIND, so it must never load a model."""
    import torch
    return {
        "ok": True,
        "device": DEVICE,
        "cuda": torch.cuda.is_available(),
        "gpu": torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
        "models": {"embed": EMBED_MODEL, "rerank": RERANK_MODEL},
        "models_loaded": _M is not None,
        "load_seconds": round(_loaded_at, 1) if _loaded_at else None,
    }


@app.post("/embed")
def embed(req: EmbedReq) -> dict:
    texts = [clean_product(t) if req.clean else t for t in req.texts]
    v = matcher().embed(texts)
    return {"n": len(texts), "dim": int(v.shape[1]), "vectors": v.cpu().tolist()}


@app.post("/score-match")
def score_match(req: ScoreReq) -> dict:
    """Raw (product, commodity-text) scoring. The honest primitive: no thresholds baked in.

    Thresholds belong to the CALLER, because the operating point is a policy decision the arrivals desk
    owns (the backtest measured 100/2816 as the point catching every known identity defect at roughly
    six rows a day). Burying it here would hide a policy choice inside a library.
    """
    pairs = [(clean_product(a), b) for a, b in req.pairs]
    return {"n": len(pairs), "scores": matcher().rerank(pairs)}


@app.post("/rank-commodity")
def rank_commodity(req: MatchReq) -> dict:
    """Rank candidate products for ONE commodity. This is the Task C shape: point it at products no rule
    matched and it surfaces the ones that belong (how the 'Cloves, Ground' gap was found)."""
    m = matcher()
    ctext = commodity_text(req.commodity)
    prods = [clean_product(p) for p in req.products]
    pv = m.embed(prods)
    cv = m.embed([ctext])[0]
    import torch
    cos = torch.mv(pv, cv).tolist()
    order = sorted(range(len(prods)), key=lambda i: -cos[i])
    top = order[:50]
    ce = m.rerank([(prods[i], ctext) for i in top]) if req.rerank else [None] * len(top)
    return {
        "commodity": req.commodity.get("id"),
        "ranked": [
            {"rank": r + 1, "product": req.products[i], "cos": round(cos[i], 4),
             "ce": (round(ce[r], 6) if ce[r] is not None else None)}
            for r, i in enumerate(top)
        ],
    }


# ---------------------------------------------------------------------------------------------
# /recall-search - the knowledge store's semantic retrieval, moved off the hook process.
#
# WHY IT IS HERE AND NOT IN THE HOOK. `~/.claude/skills/recall-hook.py` runs as a FRESH PROCESS on
# every prompt, and it was doing the cosine pass itself. Measured 2026-09-08 with `-X importtime`
# over a real prompt: interpreter 20 ms, **numpy import 66 ms**, `http.client` 20 ms, `json` 10 ms,
# `zipfile` 9 ms (np.load on the .npz), npz read 12 ms, the sidecar embed round trip 9 to 90 ms,
# and the cosine itself **0.3 ms**. p95 for the whole hook was 226 ms against a 200 ms budget.
#
# So the expensive part was never the search. It was importing the library that does it, once per
# prompt, forever - and that cost does not shrink when the corpus does. `PLAN-knowledge-at-scale`
# 4e named two remedies, memory-mapping the .npz and moving the pass here; the measurement says
# the .npz is 12 ms of the 226 and mmap could not have closed the gap. This is the other one.
#
# IT ALSO MAKES THE COST FLAT IN CORPUS SIZE, which is the plan's actual subject. The hook now
# sends one query and receives ids; ten times the store changes what this process holds in RAM and
# nothing about what the hook pays.
#
# THE CONTRACT AT THE TOP OF THIS FILE STILL HOLDS. Advisory only - it returns ranked ids and
# writes nothing. Blind, never block - the hook keeps its own numpy path and falls back to it
# silently if this endpoint is missing or errors, which is also what makes this deployable
# without coordinating a restart.
#
# THE ONE THING THAT COULD MAKE IT RETURN CONFIDENT NONSENSE is embedding the query differently
# from the way the index was built. `recall-embed-index.py` embeds with `clean=False` and L2
# normalisation; `recall_semantic.search` normalises the query the same way. Both are reproduced
# here EXACTLY, and `recall-scale-harness.py` was run over 191 cases with the endpoint on and off
# to check the injected block came back identical before the hook was allowed to prefer it.

_RECALL_IDX: dict | None = None


class RecallSearchReq(BaseModel):
    query: str
    k: int = 8
    floor: float = 0.0
    index_path: str | None = Field(
        None, description="defaults to ~/.claude/recall-embed-index.npz")
    rerank: bool = Field(False, description="cross-encode the top `pool` and reorder by that")
    pool: int = Field(24, description="how many cosine candidates the reranker sees")


def _recall_index(path: str) -> dict | None:
    """{mat, meta, mtime} for the embedding index, re-read only when the file changes.

    A long-lived process must not serve a stale index after a rebuild, and it must not re-read
    5 MB on every prompt either. `(mtime, size)` is the same staleness key `recall_index.py`
    uses on the lexical side, so the two agree about what "changed" means.
    """
    global _RECALL_IDX
    import json as _json
    import numpy as _np
    try:
        st = os.stat(path)
    except OSError:
        return None
    key = (path, st.st_mtime_ns, st.st_size)
    if _RECALL_IDX is not None and _RECALL_IDX.get("key") == key:
        return _RECALL_IDX
    try:
        z = _np.load(path, allow_pickle=False)
        mat = z["mat"]
        meta = _json.loads(str(z["meta"].item()) if hasattr(z["meta"], "item") else str(z["meta"]))
        if len(meta) != mat.shape[0]:
            return None          # a torn index is a missing index, same rule as the client
    except Exception:
        return None
    _RECALL_IDX = {"key": key, "mat": mat, "meta": meta}
    return _RECALL_IDX


@app.post("/recall-search")
def recall_search(req: RecallSearchReq) -> dict:
    """Top-k sections of the knowledge store for one query. Read-only; writes nothing."""
    import numpy as _np
    path = req.index_path or os.path.join(os.path.expanduser("~"), ".claude",
                                          "recall-embed-index.npz")
    idx = _recall_index(path)
    if idx is None:
        return {"ok": False, "why": "no usable index at %s" % path, "hits": []}
    # clean=False, because the default strips grocery pack sizes and would mangle prose. This is
    # the flag the index was built with and getting it wrong is the silent failure.
    v = matcher().embed([req.query])[0]
    qv = _np.asarray(v.cpu().tolist(), dtype=idx["mat"].dtype)
    norm = float((qv * qv).sum()) ** 0.5
    if norm:
        qv = qv / norm
    sims = idx["mat"] @ qv
    k = max(1, min(int(req.k), int(sims.shape[0])))

    if not req.rerank:
        top = _np.argsort(-sims)[:k]
        hits = [dict(idx["meta"][int(i)], score=float(sims[int(i)])) for i in top
                if float(sims[int(i)]) >= req.floor]
        return {"ok": True, "n": int(sims.shape[0]), "hits": _strip(hits)}

    # RERANK. The bi-encoder is a RECALL stage: it compares two vectors that never saw each
    # other. The cross-encoder reads the query and the passage together, which is why it is
    # the precision instrument and why it cannot be the first stage - it costs a forward pass
    # per pair. So: cosine narrows the store to `pool`, the cross-encoder orders those.
    #
    # THIS IS THE ONLY OPTION WHOSE COST DOES NOT GROW WITH THE STORE. It scores `pool` pairs
    # whether the index holds 1,300 sections or 130,000, which is the whole argument for
    # reaching for it rather than for a smarter threshold.
    #
    # THE FLOOR IS NOT REUSED. A cosine floor and a cross-encoder score are different spaces
    # and the estate has a register saying so (`sidecar/THRESHOLDS.md`). The floor still
    # gates the POOL, on cosine, where it was derived; `ce` is returned beside `score` and
    # the caller decides. Nothing here invents a threshold in a space nobody has calibrated.
    pool = max(k, min(int(req.pool), int(sims.shape[0])))
    cand = [int(i) for i in _np.argsort(-sims)[:pool]
            if float(sims[int(i)]) >= req.floor]
    if not cand:
        return {"ok": True, "n": int(sims.shape[0]), "hits": [], "reranked": 0}
    pairs = [(req.query, (idx["meta"][i].get("t") or idx["meta"][i].get("heading") or ""))
             for i in cand]
    ce = matcher().rerank(pairs)
    order = sorted(range(len(cand)), key=lambda j: -ce[j])[:k]
    hits = [dict(idx["meta"][cand[j]], score=float(sims[cand[j]]), ce=float(ce[j]))
            for j in order]
    return {"ok": True, "n": int(sims.shape[0]), "hits": _strip(hits),
            "reranked": len(cand)}


def _strip(hits):
    """The passage stays on this side. It is 2 KB a hit and the caller wants a pointer."""
    return [{k: v for k, v in h.items() if k != "t"} for h in hits]
