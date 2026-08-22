"""
score_cache.py - a persistent on-disk memo for the two GPU answers the sweep asks, so a nightly run
only pays the models for text it has never seen.

WHY
---
sweep.py used to load bge-m3 and bge-reranker-v2-m3 onto the card and re-score the WHOLE corpus every
run, 2-3 times a day, although the shelf changes by a few hundred names between runs. Measured on the
2026-08-21 corpus (37,153 rows, 3,075 board pairs): 46 s wall, of which the models' own work was ~40 s
and almost all of it a repeat of the previous run. Both answers are pure functions of
(model id, exact text), so they memoise exactly; nothing here is approximate.

WHAT IS CACHED
--------------
  embeddings   key = (EMBED_MODEL, exact text)             value = the normalised float32 vector
  rerank       key = (RERANK_MODEL, exact query, exact doc)  value = the cross-encoder score

The key is the text AFTER clean_product / commodity_text, i.e. exactly what the model saw. A commodity
whose exemplars change gets a new commodity_text and therefore fresh scores; that is correct, not a leak.

IDENTITY OF RESULTS
-------------------
A cached value IS the value a full run computed. On a warm cache the findings file is identical to a
cold run modulo `generated`/`elapsed_sec` (verified 2026-08-22 at 185 identity + 80 coverage rows).
The only way to get a different number is a model swap - and the model id is in the file name, so a
swap starts a fresh cache instead of serving stale vectors under a new name.

LAYOUT   sidecar/out/embed-cache/
  <embed-model-slug>.npy          float32 matrix, one row per cached text, in index order
  <embed-model-slug>.index.json   ["text", ...]  row i of the matrix is the vector for text i
  <rerank-model-slug>.scores.json {"querydoc": score, ...}

Both files are rewritten whole after a run with misses; ~150 MB for 37k vectors, ~1 s. If a file is
corrupt or the two embedding files disagree in length the cache is discarded and rebuilt, never trusted.
Growth is bounded by MAX_ROWS / MAX_PAIRS: past the cap the cache is rebuilt from the current run's
texts only, so a shelf that churns names for a year cannot fill the disk.

Set SWEEP_CACHE=0 in the environment to bypass the cache entirely (a cold, fully recomputed run).
"""
from __future__ import annotations
import json, os, re, time
from typing import Sequence

import numpy as np
import torch

MAX_ROWS = 250_000      # embedding rows before a rebuild-from-current
MAX_PAIRS = 2_000_000   # rerank pairs before a rebuild-from-current
_SEP = "\x1f"     # unit separator: cannot occur in a product name


def _slug(model_id: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", model_id)


def enabled() -> bool:
    return os.environ.get("SWEEP_CACHE", "1") not in ("0", "false", "no", "off")


class EmbedCache:
    def __init__(self, cache_dir: str, model_id: str):
        self.dir = cache_dir
        self.model_id = model_id
        self.npy = os.path.join(cache_dir, _slug(model_id) + ".npy")
        self.idx = os.path.join(cache_dir, _slug(model_id) + ".index.json")
        self.texts: list[str] = []
        self.mat: np.ndarray | None = None
        self.row: dict[str, int] = {}
        self.dirty = False
        self.hits = 0
        self.misses = 0
        self._load()

    def _load(self) -> None:
        if not (os.path.exists(self.npy) and os.path.exists(self.idx)):
            return
        try:
            with open(self.idx, "r", encoding="utf-8") as f:
                texts = json.load(f)
            mat = np.load(self.npy)
            if not isinstance(texts, list) or mat.ndim != 2 or mat.shape[0] != len(texts):
                raise ValueError(f"index/matrix disagree: {len(texts)} texts vs {mat.shape}")
            self.texts, self.mat = texts, mat
            self.row = {t: i for i, t in enumerate(texts)}
        except Exception as e:  # a bad cache is discarded, never trusted
            print(f"[score_cache] discarding embedding cache ({e})", flush=True)
            self.texts, self.mat, self.row = [], None, {}

    def lookup(self, texts: Sequence[str]) -> tuple[np.ndarray | None, list[int]]:
        """Returns (matrix with cached rows filled, indexes of texts that are NOT cached)."""
        missing = [i for i, t in enumerate(texts) if t not in self.row]
        self.hits += len(texts) - len(missing)
        self.misses += len(missing)
        if self.mat is None or len(missing) == len(texts):
            return None, missing
        out = np.zeros((len(texts), self.mat.shape[1]), dtype=np.float32)
        for i, t in enumerate(texts):
            r = self.row.get(t)
            if r is not None:
                out[i] = self.mat[r]
        return out, missing

    def add(self, texts: Sequence[str], vecs: np.ndarray) -> None:
        if not len(texts):
            return
        new_t, new_v = [], []
        for t, v in zip(texts, vecs):
            if t in self.row:
                continue
            self.row[t] = len(self.texts) + len(new_t)
            new_t.append(t)
            new_v.append(v)
        if not new_t:
            return
        nv = np.asarray(new_v, dtype=np.float32)
        self.mat = nv if self.mat is None else np.vstack([self.mat, nv])
        self.texts.extend(new_t)
        self.dirty = True

    def save(self, keep_only: Sequence[str] | None = None) -> None:
        if not self.dirty or self.mat is None:
            return
        if len(self.texts) > MAX_ROWS and keep_only is not None:
            keep = [t for t in dict.fromkeys(keep_only) if t in self.row]
            self.mat = self.mat[[self.row[t] for t in keep]]
            self.texts = keep
            self.row = {t: i for i, t in enumerate(keep)}
        os.makedirs(self.dir, exist_ok=True)
        tmp = self.npy + ".tmp.npy"
        np.save(tmp, self.mat)
        os.replace(tmp, self.npy)
        with open(self.idx + ".tmp", "w", encoding="utf-8") as f:
            json.dump(self.texts, f, ensure_ascii=False)
        os.replace(self.idx + ".tmp", self.idx)
        self.dirty = False


class RerankCache:
    def __init__(self, cache_dir: str, model_id: str):
        self.dir = cache_dir
        self.model_id = model_id
        self.path = os.path.join(cache_dir, _slug(model_id) + ".scores.json")
        self.scores: dict[str, float] = {}
        self.dirty = False
        self.hits = 0
        self.misses = 0
        if os.path.exists(self.path):
            try:
                with open(self.path, "r", encoding="utf-8") as f:
                    d = json.load(f)
                if not isinstance(d, dict):
                    raise ValueError("not a dict")
                self.scores = {k: float(v) for k, v in d.items()}
            except Exception as e:
                print(f"[score_cache] discarding rerank cache ({e})", flush=True)
                self.scores = {}

    @staticmethod
    def key(q: str, d: str) -> str:
        return q + _SEP + d

    def lookup(self, pairs: Sequence[tuple[str, str]]) -> tuple[list[float | None], list[int]]:
        out: list[float | None] = []
        missing: list[int] = []
        for i, (q, d) in enumerate(pairs):
            v = self.scores.get(self.key(q, d))
            out.append(v)
            if v is None:
                missing.append(i)
        self.hits += len(pairs) - len(missing)
        self.misses += len(missing)
        return out, missing

    def add(self, pairs: Sequence[tuple[str, str]], scores: Sequence[float]) -> None:
        for (q, d), s in zip(pairs, scores):
            self.scores[self.key(q, d)] = float(s)
            self.dirty = True

    def save(self, keep_only: Sequence[tuple[str, str]] | None = None) -> None:
        if not self.dirty:
            return
        if len(self.scores) > MAX_PAIRS and keep_only is not None:
            want = {self.key(q, d) for q, d in keep_only}
            self.scores = {k: v for k, v in self.scores.items() if k in want}
        os.makedirs(self.dir, exist_ok=True)
        with open(self.path + ".tmp", "w", encoding="utf-8") as f:
            json.dump(self.scores, f, ensure_ascii=False)
        os.replace(self.path + ".tmp", self.path)
        self.dirty = False


class CachedScorer:
    """Drop-in for Matcher.embed / Matcher.rerank that loads each model only when a miss needs it.

    embed_factory / rerank_factory are zero-argument callables returning an object with .embed(texts)
    or .rerank(pairs) respectively (a lib_match.Matcher holding just that model). Neither is called on
    a run where every text and every pair is already cached, so that run never touches the card.
    """

    def __init__(self, cache_dir: str, device: str, embed_factory, rerank_factory,
                 embed_model: str, rerank_model: str):
        self.device = device
        self._ef, self._rf = embed_factory, rerank_factory
        self._em = None
        self._rr = None
        self.ecache = EmbedCache(cache_dir, embed_model)
        self.rcache = RerankCache(cache_dir, rerank_model)
        self.model_load_sec = 0.0
        self.gpu_sec = 0.0
        self._seen_texts: list[str] = []
        self._seen_pairs: list[tuple[str, str]] = []

    def _embedder(self):
        if self._em is None:
            t0 = time.time()
            self._em = self._ef()
            self.model_load_sec += time.time() - t0
        return self._em

    def _reranker(self):
        if self._rr is None:
            t0 = time.time()
            self._rr = self._rf()
            self.model_load_sec += time.time() - t0
        return self._rr

    def embed(self, texts: Sequence[str]) -> torch.Tensor:
        texts = [str(t) for t in texts]
        self._seen_texts.extend(texts)
        mat, missing = self.ecache.lookup(texts)
        if missing:
            t0 = time.time()
            fresh = self._embedder().embed([texts[i] for i in missing]).detach().cpu().numpy().astype(np.float32)
            self.gpu_sec += time.time() - t0
            self.ecache.add([texts[i] for i in missing], fresh)
            if mat is None:
                mat = np.zeros((len(texts), fresh.shape[1]), dtype=np.float32)
            for k, i in enumerate(missing):
                mat[i] = fresh[k]
        return torch.from_numpy(mat).to(self.device)

    def rerank(self, pairs: Sequence[tuple[str, str]]) -> list[float]:
        pairs = [(str(q), str(d)) for q, d in pairs]
        self._seen_pairs.extend(pairs)
        out, missing = self.rcache.lookup(pairs)
        if missing:
            t0 = time.time()
            fresh = self._reranker().rerank([pairs[i] for i in missing])
            self.gpu_sec += time.time() - t0
            self.rcache.add([pairs[i] for i in missing], fresh)
            for k, i in enumerate(missing):
                out[i] = fresh[k]
        return [float(x) for x in out]  # type: ignore[arg-type]

    def save(self) -> None:
        self.ecache.save(keep_only=self._seen_texts)
        self.rcache.save(keep_only=self._seen_pairs)

    def stats(self) -> dict:
        return {
            "embed_hits": self.ecache.hits, "embed_misses": self.ecache.misses,
            "rerank_hits": self.rcache.hits, "rerank_misses": self.rcache.misses,
            "embedder_loaded": self._em is not None, "reranker_loaded": self._rr is not None,
            "model_load_sec": round(self.model_load_sec, 1), "gpu_sec": round(self.gpu_sec, 1),
        }
