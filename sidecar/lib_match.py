"""
lib_match.py - THE semantic identity matcher. One implementation, shared by the backtest and the service.

WHY THIS EXISTS
---------------
The estate matches products to commodities with 48,242 hand-maintained regex patterns. That works until
the shelf phrases something a pattern-writer did not anticipate, and then it fails SILENTLY and in both
directions:

  * a wrong product wearing a crown  - "Dr Teal's Foaming Bath ... with Coconut Oil" matched as coconut oil
  * a right product nobody can see   - "Cloves, Ground" invisible to a rule that only knew "ground cloves",
                                        so a $45 jar won the cell unopposed on 2026-08-01

Both are semantic entailment questions ("is this product an instance of this commodity?"). This module
answers them with embeddings plus a cross-encoder, on the GPU, over the whole catalogue at once.

WHAT IT IS NOT
--------------
It is ADVISORY. It never picks a crown, never edits a rule, never changes a price. It produces ranked
suspicion, which flows into the arrivals desk / contested-match / coverage reports where a human or a
frontier agent adjudicates. That boundary is the whole reason it is safe to run unattended.

DESIGN NOTES
------------
* Commodity text is built from LABEL + EXEMPLARS, not from the regex. Feeding the model the patterns
  would just relaunder the same blind spot in vector form; exemplars are what the board actually
  accepted, which is real supervision we already own (~2,816 vetted pairs).
* Bi-encoder first (cheap, all pairs), cross-encoder second (expensive, only the shortlist). Same
  retrieve-then-rerank shape every serious retrieval system uses, and it is what makes 22,884 x 503
  tractable.
* Scores are calibrated per commodity against ITS OWN accepted products, because "0.62 similarity"
  means different things for "Milk" than for "Aji Amarillo Paste". A raw global threshold would drown
  the narrow commodities in false positives and miss the broad ones entirely.
"""
from __future__ import annotations
import json, os, re
from dataclasses import dataclass
from typing import Iterable, Sequence

import torch
from sentence_transformers import SentenceTransformer, CrossEncoder

# Pinned on purpose. A model swap changes every score in the estate, so it is a deliberate, fixtured act
# (see the drift watch in the design doc), never an implicit `latest`.
EMBED_MODEL = "BAAI/bge-m3"
RERANK_MODEL = "BAAI/bge-reranker-v2-m3"

DEVICE = "cuda" if torch.cuda.is_available() else "cpu"

_UNIT_TAIL = re.compile(
    r"[,\s]*\b\d+(\.\d+)?\s*"
    r"(fl\s*oz|oz|lb|lbs|ct|count|pk|pack|g|kg|ml|l|qt|gal|each|ea|in|sq\s*ft)\b\.?\s*$",
    re.I,
)


def clean_product(name: str) -> str:
    """Trim trailing pack/size noise so the model compares WHAT a thing is, not how much of it there is.

    Sizes are load-bearing for pricing and meaningless for identity: "Our Family Cloves, Ground 2 Oz" and
    "Tone's Cloves, Ground 0.55 Oz" are the same commodity. The pricing engine keeps the size; the matcher
    should not be distracted by it. Applied repeatedly because names often carry two size tails.
    """
    s = (name or "").strip()
    for _ in range(3):
        s2 = _UNIT_TAIL.sub("", s).strip(" ,;-")
        if s2 == s:
            break
        s = s2
    return s or (name or "").strip()


def commodity_text(d: dict) -> str:
    """Natural-language stand-in for a commodity: what it IS, plus what the board has accepted as one.

    Deliberately excludes the regex. The patterns encode a pattern-writer's guesses about phrasing, which
    is precisely the failure mode being replaced.
    """
    label = (d.get("label") or d.get("id") or "").strip()
    ex = [clean_product(x) for x in (d.get("exemplars") or [])][:5]
    parts = [f"grocery product: {label}"]
    if ex:
        parts.append("examples: " + "; ".join(ex))
    return ". ".join(parts)


@dataclass
class Matcher:
    embed_model: SentenceTransformer | None
    rerank_model: CrossEncoder | None
    # WHICH cross-encoder this instance actually holds. Not decoration: a candidate copy and the pinned
    # one produce different numbers for the same pair, so every report that quotes a score has to be
    # able to say which model produced it. A run that cannot name its model is a run nobody can
    # reproduce, and the estate has already paid for that lesson in the drift watch.
    rerank_id: str = RERANK_MODEL

    @classmethod
    def load(cls, with_reranker: bool = True, reranker_path: str | None = None) -> "Matcher":
        em = SentenceTransformer(EMBED_MODEL, device=DEVICE)
        em.max_seq_length = 96  # product names are short; this is a large throughput win
        rr = cls._reranker(reranker_path) if with_reranker else None
        return cls(em, rr, reranker_path or RERANK_MODEL)

    @classmethod
    def load_reranker_only(cls, reranker_path: str | None = None) -> "Matcher":
        """The cross-encoder without the bi-encoder, for a caller (sweep.py's score cache) whose
        embeddings are already on disk. Same pinned model and max_length as load()."""
        return cls(None, cls._reranker(reranker_path), reranker_path or RERANK_MODEL)

    @staticmethod
    def _reranker(path: str | None = None) -> CrossEncoder:
        """The pinned cross-encoder, or an EXPLICIT candidate copy.

        THE OVERRIDE DOES NOT MOVE THE PIN, and that distinction is the whole point (sidecar rule 3:
        a model swap changes every score in the estate, so it is a deliberate, fixtured act, never an
        implicit `latest`). RERANK_MODEL stays what it is; `path` is a caller saying, for this one
        run, score with THIS copy instead - which is exactly what PLAN-local-matching section 6 needs
        to gate a fine-tune: beat stock on the holdout AND still catch 24 of 24 known defects, both
        measured by pointing backtest.py at the candidate while the sweep keeps scoring on the pin.

        Passing a path here NEVER changes what sweep.py loads. sweep.py does not take one.
        """
        return CrossEncoder(path or RERANK_MODEL, device=DEVICE, max_length=160)

    def embed(self, texts: Sequence[str], batch_size: int = 256) -> torch.Tensor:
        return self.embed_model.encode(
            list(texts),
            batch_size=batch_size,
            convert_to_tensor=True,
            normalize_embeddings=True,
            show_progress_bar=False,
            device=DEVICE,
        )

    def rerank(self, pairs: Sequence[tuple[str, str]], batch_size: int = 128) -> list[float]:
        if not pairs:
            return []
        if self.rerank_model is None:
            raise RuntimeError("reranker not loaded")
        scores = self.rerank_model.predict(list(pairs), batch_size=batch_size, show_progress_bar=False)
        return [float(x) for x in scores]


def load_json(path: str):
    with open(path, "r", encoding="utf-8-sig") as f:
        return json.load(f)


def calibrate(scores_by_commodity: dict[str, list[float]], q: float = 0.10) -> dict[str, float]:
    """Per-commodity floor: the q-quantile of scores its OWN accepted products earn.

    A global threshold cannot work. "Milk" sits in a dense neighbourhood of dairy words; "Aji Amarillo
    Paste" sits almost alone. Calibrating against each commodity's accepted set asks the only question
    that generalises: is this product an outlier AMONG THE THINGS THIS COMMODITY ALREADY ACCEPTS?
    """
    out: dict[str, float] = {}
    for cid, vals in scores_by_commodity.items():
        if not vals:
            continue
        v = sorted(vals)
        idx = max(0, min(len(v) - 1, int(q * (len(v) - 1))))
        out[cid] = v[idx]
    return out
