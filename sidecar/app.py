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
