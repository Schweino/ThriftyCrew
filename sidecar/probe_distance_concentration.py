"""Is a single global similarity floor a claim the vector space supports? (2026-09-09, backlog I49)

WHAT THIS MEASURES, and it is deliberately not a clustering project.

`sidecar/THRESHOLDS.md` carries one global cosine floor for the bi-encoder. That is a claim about the
SHAPE of the space: that a single cut separates near from far everywhere in it. In high dimension that
claim can fail silently through DISTANCE CONCENTRATION - as dimension rises, the nearest and furthest
neighbours of a point drift toward the same distance, the ordering under a fixed cut becomes close to
noise, and the floor keeps returning confident numbers the whole time.

The standard instrument is RELATIVE CONTRAST, per point:

    RC = d_far / d_near

over the other points in the sample. RC near 1 means the point's nearest and furthest neighbours are
nearly equidistant and a global cut is the wrong instrument. RC comfortably above 1 means the space has
usable structure at this dimension and the current single-floor design is sound.

THE ACCEPTANCE BAR IS WRITTEN HERE, ABOVE THE RUN, IN THE METRIC'S OWN UNITS (backlog E21). A threshold
picked after seeing the number is not a threshold, it is a description of a decision already taken.

    median RC >= 1.50   the space has usable structure; ONE GLOBAL FLOOR IS A SOUND INSTRUMENT
    median RC <  1.20   distance concentration; a global cut is close to noise and I49 rung 2 is owed
    in between          AMBIGUOUS, and it is reported as ambiguous rather than rounded to a verdict

A SECOND STATISTIC, because the median alone hides the case that matters. If contrast varies a lot
BETWEEN points, then a single floor is wrong for some regions even when the median looks healthy. So the
10th percentile is reported too, and the fraction of points whose RC is under 1.20.

WHAT THIS IS NOT. It says nothing about whether 0.55 is the right value. It asks only whether a single
global value is the right SHAPE of answer. `sidecar/derive_coverage_floor.py` is the tool that argues
about the value, from labelled pairs.

ONE ROW PER CASE (backlog E24): every sampled point gets a row in the .jsonl, so the totals are derived
from the file and a later question can be asked of the same run without re-running it.

    python sidecar/probe_distance_concentration.py
    python sidecar/probe_distance_concentration.py --selftest
Exit 0 ok, 2 self-test failure, 3 could not evaluate (no cache to read - never a pass).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

BAR_SOUND = 1.50
BAR_CONCENTRATED = 1.20
SAMPLE_N = 2000
SEED = 20260909


def relative_contrast(vecs: np.ndarray) -> np.ndarray:
    """RC per row: (distance to furthest other point) / (distance to nearest other point).

    Cosine distance, because the floor this is about is a COSINE floor. The vectors are L2-normalised
    first so the dot product IS the cosine; the caches are written normalised, but asserting it costs
    nothing and a silently unnormalised cache would make every number here meaningless.
    """
    n = vecs.shape[0]
    if n < 3:
        raise ValueError("need at least 3 points")
    norms = np.linalg.norm(vecs, axis=1, keepdims=True)
    norms[norms == 0] = 1.0
    v = vecs / norms
    sims = v @ v.T
    np.fill_diagonal(sims, np.nan)          # a point is not its own neighbour
    d = 1.0 - sims                          # cosine distance
    d_near = np.nanmin(d, axis=1)
    d_far = np.nanmax(d, axis=1)
    # A point whose nearest neighbour is an exact duplicate has d_near 0 and RC is undefined, not
    # infinite. Those rows are REPORTED AND EXCLUDED rather than clipped to a large number, because
    # clipping would inflate the median in the direction of the answer we would like.
    with np.errstate(divide="ignore", invalid="ignore"):
        rc = np.where(d_near > 1e-9, d_far / np.maximum(d_near, 1e-12), np.nan)
    return rc


def verdict(median_rc: float) -> str:
    if median_rc >= BAR_SOUND:
        return "SOUND"
    if median_rc < BAR_CONCENTRATED:
        return "CONCENTRATED"
    return "AMBIGUOUS"


def _selftest() -> int:
    bad = 0

    def T(name, ok, got=""):
        nonlocal bad
        if ok:
            print("  ok    " + name)
        else:
            print("  X     " + name + "   got: " + str(got))
            bad += 1

    # MUST FIRE: a space with real structure scores well above 1. Three tight clusters far apart.
    rng = np.random.default_rng(1)
    centres = np.eye(3) * 10.0
    pts = np.vstack([c + rng.normal(0, 0.01, (20, 3)) for c in centres])
    rc = relative_contrast(pts)
    T("MUST FIRE  a clearly clustered space has high relative contrast",
      float(np.nanmedian(rc)) > 5.0, float(np.nanmedian(rc)))
    T("and it is called SOUND", verdict(float(np.nanmedian(rc))) == "SOUND", verdict(float(np.nanmedian(rc))))

    # MUST FIRE: the founding failure. Points on a high-dimensional sphere concentrate, so RC -> 1 and
    # a single global cut is close to noise. This is the case the estate has never checked for.
    hi = rng.normal(0, 1, (300, 1024))
    rc_hi = relative_contrast(hi)
    med_hi = float(np.nanmedian(rc_hi))
    T("MUST FIRE  uniform high-dimensional noise concentrates (RC near 1)", med_hi < BAR_SOUND, med_hi)
    T("and it is NOT called SOUND", verdict(med_hi) != "SOUND", verdict(med_hi))

    # MUST NOT FIRE: the in-between band is reported as ambiguous, not rounded to a verdict.
    T("MUST NOT FIRE  a mid-band median is AMBIGUOUS, not forced either way",
      verdict(1.35) == "AMBIGUOUS", verdict(1.35))
    T("the bars are the ones written above the run", (BAR_SOUND, BAR_CONCENTRATED) == (1.50, 1.20),
      str((BAR_SOUND, BAR_CONCENTRATED)))

    # MUST NOT FIRE: an exact duplicate makes RC undefined for that row, not infinite.
    dup = np.vstack([np.array([[1.0, 0, 0], [1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]])])
    rc_d = relative_contrast(dup)
    T("MUST NOT FIRE  a duplicate row is NaN (excluded), never inf",
      bool(np.isnan(rc_d[0])) and not np.isinf(rc_d).any(), str(rc_d[:2]))

    # CLEAN TWIN: normalisation still leaves the clustered case scoring high, so the assertion above is
    # not an artefact of unnormalised magnitudes.
    rc_scaled = relative_contrast(pts * 7.3)
    T("CLEAN TWIN  scaling every vector does not change the verdict",
      verdict(float(np.nanmedian(rc_scaled))) == verdict(float(np.nanmedian(rc))),
      verdict(float(np.nanmedian(rc_scaled))))

    if bad:
        print("distance-concentration SELF-TEST FAIL (%d)" % bad)
        return 2
    print("distance-concentration SELF-TEST PASS")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--cache", default=os.path.join(HERE, "out", "embed-cache", "BAAI_bge-m3.npy"))
    ap.add_argument("--out", default=os.path.join(HERE, "out", "distance-concentration.jsonl"))
    args = ap.parse_args()

    if args.selftest:
        return _selftest()

    if not os.path.exists(args.cache):
        print("distance-concentration: no embedding cache at %s - BLIND, not clean." % args.cache)
        return 3
    vecs = np.load(args.cache)
    total = vecs.shape[0]
    if total < 50:
        print("distance-concentration: only %d vectors - too few to say anything. BLIND." % total)
        return 3

    # An INPUT FINGERPRINT with the result, because a probe that disagrees with itself across two runs
    # and recorded nothing about what it read cannot be debugged.
    with open(args.cache, "rb") as fh:
        fh.seek(0)
        head = fh.read(1 << 20)
    fp = hashlib.sha256(head).hexdigest()[:16]

    rng = np.random.default_rng(SEED)
    n = min(SAMPLE_N, total)
    idx = rng.choice(total, size=n, replace=False)
    sample = vecs[idx].astype(np.float32)

    rc = relative_contrast(sample)
    undefined = int(np.isnan(rc).sum())
    good = rc[~np.isnan(rc)]
    med = float(np.median(good))
    p10 = float(np.percentile(good, 10))
    p90 = float(np.percentile(good, 90))
    frac_low = float((good < BAR_CONCENTRATED).mean())

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
        for i, row_idx in enumerate(idx):
            v = rc[i]
            fh.write(json.dumps({"row": int(row_idx), "rc": (None if np.isnan(v) else round(float(v), 6)),
                                 "cache_fp": fp, "seed": SEED}) + "\n")

    print("distance-concentration: sampled %d of %d vector(s) (%.1f%%), dim %d, cache fp %s"
          % (n, total, 100.0 * n / total, sample.shape[1], fp))
    print("  relative contrast  median %.3f   p10 %.3f   p90 %.3f" % (med, p10, p90))
    print("  points with RC < %.2f: %d of %d (%.1f%%)"
          % (BAR_CONCENTRATED, int((good < BAR_CONCENTRATED).sum()), good.size, 100.0 * frac_low))
    if undefined:
        print("  %d point(s) had an exact duplicate nearest neighbour: RC undefined, EXCLUDED not clipped"
              % undefined)
    v = verdict(med)
    print("  BAR (written before the run): >= %.2f SOUND, < %.2f CONCENTRATED" % (BAR_SOUND, BAR_CONCENTRATED))
    print("  VERDICT: %s" % v)
    if v == "SOUND":
        print("  One global floor is the right SHAPE of instrument for this space. It says nothing about")
        print("  whether 0.55 is the right VALUE - that is derive_coverage_floor.py's question.")
    elif v == "CONCENTRATED":
        print("  A single global cut is close to noise here. I49 rung 2 (per-region floors) is owed.")
    else:
        print("  AMBIGUOUS. Reported as ambiguous rather than rounded toward a verdict.")
    print("  rows written to %s" % args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
