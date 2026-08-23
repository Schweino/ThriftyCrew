"""
sweep.py - the nightly GPU batch. Reads a corpus prepared by the PowerShell side, writes ranked
advisory findings. It does the scoring and NOTHING else.

DIVISION OF LABOUR (deliberate)
-------------------------------
PowerShell owns which products exist and which rules match them, because that regex must stay
byte-identical to what the pricing engine does; a second copy in Python is exactly the
two-implementations bug this estate keeps getting bitten by (pu-lib had three, the category-exclude
bake drifted 2,165 patterns, the record tooltips carried a second price formatter). Python owns the
GPU maths. Neither reimplements the other.

TWO LANES, both advisory:

  IDENTITY  - for every (product, commodity) pair the board ships, how well does the product actually
              match what the commodity means? Low scores are candidate wrong-crowns. This is the
              bath-soap-as-coconut-oil class, which no price check can catch.

  COVERAGE  - for every product NO rule matches, which commodity does it look like? High scores are
              candidate blind spots. This is the "Cloves, Ground" class: the right product sitting in
              the feed, invisible, while a $45 jar wins the cell unopposed.

  CONTESTED - (2026-08-22, PLAN-local-matching phase 2) the pairs the graph's deterministic layers
              could not settle, scored while the models are already resident. Writes
              out/contested-scores.json and, just as importantly, leaves the vectors and pair scores
              in the on-disk cache, so the resolve lane — which runs HOURS later, on a card this
              process has already given back — pays nothing for them.

              THIS LANE DECIDES NOTHING. Phase 2 caches; phase 3 trains the helper and lets it
              filter. Recording a score is not the same act as acting on one, and keeping them
              separate is what lets phase 3 measure the filter against a set that was scored before
              anyone knew what the filter would do.

WHY THE SWEEP AND NOT A SCRIPT OF ITS OWN. score_cache prunes on save to the texts the run saw
(keep_only=_seen_texts), so a vector some other process produced is evicted the next time the sweep
saves. One process, one cache, one save.

Output: out/semantic-findings.json + out/contested-scores.json. Nothing else is written, and nothing
is applied.
"""
from __future__ import annotations
import json, os, sys, time

import torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib_match import Matcher, clean_product, commodity_text, load_json, DEVICE, EMBED_MODEL, RERANK_MODEL
import score_cache

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
OUT = os.path.join(HERE, "out")
CACHE = os.path.join(OUT, "embed-cache")
os.makedirs(OUT, exist_ok=True)

# Operating points from the Phase 1 backtest (backtest-report.md). IDENTITY_KEEP is the 100/2816
# threshold that caught 24 of 24 identity defects; COVERAGE_MIN is set where Task C's true positives
# sat (the cloves/ginger/red-pepper hits scored 0.58-0.69 on cosine).
# A shipped pair is suspicious when it scores far BELOW its own commodity's median, not below a global
# bar. 0.10 = "less than a tenth as good a match as this commodity's typical accepted product".
IDENTITY_PEER_RATIO = 0.10
COVERAGE_COS_FLOOR = 0.55        # bi-encoder cosine; cheap prefilter, NOT the decision
# The coverage floor was set on evidence, not taste. The first full sweep at 0.05 returned 1,404 rows,
# which is a firehose nobody reads, and a guard nobody reads is worse than no guard (see the link-drift
# alert that fired daily on unfixable cells until 2026-08-01). Sampling the bands:
#   >=0.95 -> 35 rows, nearly all real     >=0.90 -> 89 rows, still nearly all real
#   >=0.80 -> 163, mixed                   >=0.20 -> 843, mostly near-misses the rules correctly reject
# 0.90 keeps the real gaps (La Costena "Jalapeno Peppers, Pickled", Hormel "Corned Beef, Hash" - both the
# same inverted-name shape that cost a live cell) while dropping the Tide-liquid-for-detergent-PODS class
# of near miss. Findings also cluster hard by commodity (12 of the 89 are one detergent), so the report
# groups them: a human reviews "this commodity is missing 12 products" once, not twelve times.
COVERAGE_RERANK_FLOOR = 0.90


def log(m: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


def resolve_definition(pair, by_node, defs_by_id):
    """Which commodity definition does this contested pair mean? Returns (def_or_None, reason).

    WHY THIS IS NOT A DICT LOOKUP. 33 bare ids name a commodity in BOTH namespaces - milk, butter,
    brown-sugar, carrots, peanut-butter, honey - so keying on `def_id` alone will happily score a
    RECIPE question against the STAPLE's text. For near-identical foods that produces a PLAUSIBLE
    number rather than a missing one, which is the worse failure of the two: a missing score is a
    cache miss anyone can see, and a plausible wrong one is never questioned.

    So the full node id wins wherever the definitions carry one, and the bare-id fallback is allowed
    only when the namespaces agree. Today's commodity-defs.json is built by PowerShell from
    grocery/commodities.json and carries neither field; every entry in it is a staple, which is what
    an absent `namespace` is taken to mean.

    reason is one of: node_id (exact), bare_id (fallback, namespaces agreed), wrong_namespace
    (REFUSED - the bare id exists but belongs to the other namespace), unknown (no definition).
    """
    d = by_node.get(pair.get("id"))
    if d is not None:
        return d, "node_id"
    d = defs_by_id.get(pair.get("def_id"))
    if d is None:
        return None, "unknown"
    nid = pair.get("id") or ""
    want = nid.split(":")[1] if nid.count(":") >= 2 else ""
    have = d.get("namespace") or "staple"
    if want and want != have:
        return None, "wrong_namespace"
    return d, "bare_id"


def _selftest() -> int:
    """Fixtures for the one piece of this file that can be wrong SILENTLY."""
    bad = 0

    def T(name, ok, got=""):
        nonlocal bad
        if ok:
            print(f"  ok    {name}")
        else:
            print(f"  X     {name}   got: {got!r}")
            bad += 1

    staple = {"id": "brown-sugar", "node_id": "commodity:staple:brown-sugar",
              "label": "Brown Sugar", "namespace": "staple", "exemplars": []}
    recipe = {"id": "brown-sugar", "node_id": "commodity:recipe:brown-sugar",
              "label": "Brown Sugar (recipe)", "namespace": "recipe", "exemplars": []}
    legacy = {"id": "brown-sugar", "label": "Brown Sugar", "exemplars": []}   # PowerShell's file

    both = [staple, recipe]
    by_node = {d["node_id"]: d for d in both}
    # defs_by_id collapses the collision - which is exactly why by_node exists
    by_id = {d["id"]: d for d in both}

    d, why = resolve_definition({"id": "commodity:recipe:brown-sugar", "def_id": "brown-sugar"},
                                by_node, by_id)
    T("a recipe question resolves to the RECIPE definition", d is recipe and why == "node_id", why)
    d, why = resolve_definition({"id": "commodity:staple:brown-sugar", "def_id": "brown-sugar"},
                                by_node, by_id)
    T("a staple question resolves to the STAPLE definition", d is staple and why == "node_id", why)

    # MUST FIRE: against the legacy all-staple file, a RECIPE question must be refused, never
    # scored against the staple's text. This is the silent-wrong-answer case.
    d, why = resolve_definition({"id": "commodity:recipe:brown-sugar", "def_id": "brown-sugar"},
                                {}, {"brown-sugar": legacy})
    T("MUST FIRE  a recipe question is REFUSED against a staple-only definition",
      d is None and why == "wrong_namespace", why)
    # CLEAN TWIN: the staple question against the same file is fine.
    d, why = resolve_definition({"id": "commodity:staple:brown-sugar", "def_id": "brown-sugar"},
                                {}, {"brown-sugar": legacy})
    T("CLEAN TWIN  a staple question against the same file still resolves",
      d is legacy and why == "bare_id", why)
    # CLEAN TWIN: a commodity nobody defines is 'unknown', which is a different fact from a refusal.
    d, why = resolve_definition({"id": "commodity:recipe:capers", "def_id": "capers"}, {}, {})
    T("CLEAN TWIN  an undefined commodity is unknown, not a refusal",
      d is None and why == "unknown", why)

    if bad:
        print(f"sweep SELF-TEST FAIL ({bad})")
        return 2
    print("sweep SELF-TEST PASS")
    return 0


def loo_peers(m, d: dict) -> tuple[float, float, int] | None:
    """A peer distribution for a commodity the board itself has no shipped pairs for.

    THE HOLE THIS FILLS, re-measured 2026-08-23 at full scale. The plan says ~30% of contested
    pairs have peer_n = 0 "because the commodity ships nothing today". At 435 pairs it is 420 of
    435 - 97% - and the cause is not an empty shelf: all 54 contested commodities have accepted
    products in the graph. The peers were missing because the peer source is the identity lane's
    BOARD pairs, which are the staple catalogue, and 97% of contested questions are recipe
    commodities. Wrong catalogue, not empty shelf.

    LEAVE ONE OUT, because the definition contains the answer. commodity_text() is label + up to 5
    accepted products, so scoring an exemplar against its own commodity's text asks the model to
    find a string that is literally printed in the document; it would score ~1.0 and hand back a
    peer median no real pair could clear. Each exemplar is scored against the text of the OTHER
    exemplars instead. This is the same ruling phase 1 made about the bench's retrieved priors,
    for the same reason, and `--priors loo` is where it was made.

    Returns None below 2 exemplars: one exemplar leaves a label-only document, which measured AUC
    0.7921 against 0.9705 with exemplars. A calibration that weak is worse than no calibration,
    and the filter's answer to no calibration is to abstain.
    """
    ex = [clean_product(x) for x in (d.get("exemplars") or [])][:5]
    if len(ex) < 2:
        return None
    pairs = []
    for i, e in enumerate(ex):
        others = dict(d)
        others["exemplars"] = [x for j, x in enumerate(ex) if j != i]
        pairs.append((e, commodity_text(others)))
    vals = sorted(float(v) for v in m.rerank(pairs))
    p10 = vals[max(0, min(len(vals) - 1, int(0.10 * (len(vals) - 1))))]
    return vals[len(vals) // 2], p10, len(vals)


def run_contested_lane(m, defs, defs_by_id, ctexts, cvecs, cidx, by_com, ce_all, defs_path="",
                       helper=None, helper_id=""):
    """LANE 3 - score the graph's contested questions, and warm every vector the resolve lane wants.

    Returns None when there is nothing to do (no file, or an unreadable one). A missing or stale
    contested file is NEVER an error here: this lane is a cache-warmer with an advisory report
    attached, and the resolve lane treats a missing score exactly as it treats any cache miss.

    WHAT IS WRITTEN, AND WHY EACH FIELD IS THERE
      score        the cross-encoder's raw number for (product, commodity_text). The quantity
                   phase 3's trained helper replaces, measured today with the stock model so the
                   retrain has a before.
      cos          the bi-encoder cosine. Cheap, and the only signal available for a commodity with
                   too few shipped peers to calibrate against.
      peer_median  the median score THIS commodity's own shipped products earn, and peer_p10 the
                   tenth percentile of the same. A raw floor cannot work and this sweep already
                   learned why: short generic names score low against everything, so an absolute bar
                   selects for short names and flags "Yellow Bananas" as suspicious bananas. The
                   honest question is whether a pair is an outlier AMONG ITS OWN PEERS, so the
                   calibration travels WITH the score. peer_n says how much to trust it.

    peers come from the identity lane's ce_all, which has already reranked every shipped board pair
    on this run - the same numbers, no second model call.
    """
    path = os.path.join(DATA, "contested-pairs.json")
    if not os.path.exists(path):
        log("LANE contested: no data/contested-pairs.json - skipped (run resolve.py --emit-contested)")
        return None
    try:
        doc = load_json(path)
        pairs = doc["pairs"]
        texts = doc.get("embed_texts") or []
    except Exception as e:                                                        # noqa: BLE001
        log(f"LANE contested: unreadable contested file ({e}) - skipped")
        return None

    t0 = time.time()
    # Every text the resolve lane will want a vector for, embedded in THIS run so the save keeps it.
    # Cached texts cost nothing; the misses are what this line is for.
    if texts:
        m.embed([clean_product(t) for t in texts])
        log(f"LANE contested: warmed {len(texts)} product vector(s) for the resolve lane")

    # Per-commodity peer calibration from the shipped pairs the identity lane already scored.
    peers = {}
    for cid, idxs in by_com.items():
        vals = sorted(ce_all[i] for i in idxs)
        p10 = vals[max(0, min(len(vals) - 1, int(0.10 * (len(vals) - 1))))]
        peers[cid] = (vals[len(vals) // 2], p10, len(vals))

    # Built from the DEFS LIST, never from defs_by_id: that dict is keyed by bare id, so the 33
    # colliding commodities are already collapsed inside it and 33 node_ids would simply be absent
    # here - the very collision this lookup exists to avoid, one level up.
    by_node = {d["node_id"]: d for d in defs if d.get("node_id")}

    known, unknown, wrong_ns = [], [], 0
    for p in pairs:
        d, why = resolve_definition(p, by_node, defs_by_id)
        if d is None:
            unknown.append(p)
            if why == "wrong_namespace":
                wrong_ns += 1
        else:
            p["_def"] = d
            known.append(p)
    if unknown:
        # A contested commodity the sidecar has no definition for is a real thing - the recipe
        # namespace and the staple catalogue are not the same set - and it is reported, not guessed.
        log(f"LANE contested: {len(unknown)} pair(s) name a commodity with no sidecar definition; not scored")
        if wrong_ns:
            log(f"  of those, {wrong_ns} share a bare id with a DIFFERENT namespace's commodity and "
                f"were refused rather than scored against the wrong definition")

    scored = []
    if known:
        names = [clean_product(p["product"]) for p in known]
        pvecs = m.embed(names)
        # Text from the RESOLVED definition. ctexts/cidx are keyed by bare id and would reintroduce
        # the collision this lane just refused, so they are used only for the peer calibration
        # below, where the identity lane's own bare-id world is the right frame.
        dtexts = [commodity_text(p["_def"]) for p in known]
        dvecs = m.embed(dtexts)
        rpairs = [(names[i], dtexts[i]) for i in range(len(known))]
        ce = m.rerank(rpairs)
        # THE HELPER'S OWN OPINION, from its own copy of the weights and its own cache file.
        # The pinned model's number stays in `score` regardless: it is the estate's continuous
        # record, it is what every earlier night wrote, and a phase that silently replaced it
        # would make the before/after unreadable. Two models, two columns, both named.
        hs = list(helper.rerank(rpairs)) if helper is not None else None
        # Board peers where they exist, leave-one-out peers where they do not, and the row says
        # WHICH - two calibrations in one unlabelled column would be indistinguishable from one.
        loo_cache: dict[str, tuple | None] = {}
        for i, p in enumerate(known):
            did = p["def_id"]
            src = "board"
            got = peers.get(did)
            if got is None:
                node = p["_def"].get("node_id") or did
                if node not in loo_cache:
                    # Calibrate with the model whose scores the filter will read. A helper score
                    # against a peer median produced by a DIFFERENT model is not a ratio, it is
                    # two unrelated numbers divided by each other.
                    loo_cache[node] = loo_peers(helper or m, p["_def"])
                got = loo_cache[node]
                src = "exemplars_loo" if got else "none"
            med, p10, n_peers = got if got else (None, None, 0)
            scored.append({
                "id": p["id"], "def_id": did, "commodity": p.get("commodity"),
                "namespace": p["_def"].get("namespace") or "staple",
                "product": p["product"], "rows": p.get("rows", 1),
                "cos": round(float(torch.dot(pvecs[i], dvecs[i])), 4),
                "score": round(float(ce[i]), 6),
                "helper_score": (round(float(hs[i]), 6) if hs is not None else None),
                "peer_median": None if med is None else round(float(med), 6),
                "peer_p10": None if p10 is None else round(float(p10), 6),
                "peer_n": n_peers,
                # board = this commodity's own shipped products, scored by the identity lane.
                # exemplars_loo = its accepted examples, each scored against the others (loo_peers).
                # none = fewer than 2 examples; the filter abstains rather than invent a floor.
                "peer_source": src,
            })
    scored.sort(key=lambda r: r["score"])
    log(f"LANE contested: scored {len(scored)} pair(s) in {time.time()-t0:.1f}s")
    return {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "source_generated": doc.get("generated"),
        "embed_model": EMBED_MODEL,
        "rerank_model": RERANK_MODEL,
        "helper_model": helper_id or None,
        "elapsed_sec": round(time.time() - t0, 1),
        "advisory": "scores only - nothing here filters, routes or prices anything (phase 3 does that)",
        "defs": os.path.basename(defs_path) if defs_path else "",
        "definitions": len(defs),
        "offered": len(pairs),
        "scored": len(scored),
        "no_definition": len(unknown),
        "refused_wrong_namespace": wrong_ns,
        "vectors_warmed": len(texts),
        "pairs": scored,
    }

def main(defs_path: str | None = None, tag: str = "", contested_defs_path: str | None = None,
         helper_path: str | None = None) -> None:
    t_start = time.time()
    # A comparison run must not overwrite the findings the daily alert de-dupes against: a changed
    # signature file would make every standing finding look new exactly once, which is the alert
    # noise this estate rates as worse than no alert at all.
    suffix = f"-{tag}" if tag else ""
    defs_path = defs_path or os.path.join(DATA, "commodity-defs.json")
    defs = load_json(defs_path)
    log(f"defs={os.path.basename(defs_path)}{'  (COMPARISON RUN, tag ' + tag + ')' if tag else ''}")
    # ONE DEF SET PER LANE, AND THEY ARE NOT THE SAME SET. Measured 2026-08-22: switching all three
    # lanes to the graph's definitions takes the contested lane from 15 of 435 pairs to 435 of 435,
    # and reshuffles the identity lane 181 -> 255 with 130 GONE. Those 130 are pairs the estate is
    # shown today and would stop being shown with no event marking it, which this board rates worse
    # than a noisy guard - so the switch is NOT made wholesale. The contested lane, whose questions
    # come from the graph and are 97% recipe-namespace, gets the graph's definitions; identity and
    # coverage keep the staple catalogue they have always read, and the daily alert does not move.
    cdefs = defs
    if contested_defs_path:
        cdefs = load_json(contested_defs_path)
        log(f"contested-defs={os.path.basename(contested_defs_path)} ({len(cdefs)} definitions) - "
            f"LANE 3 ONLY; identity and coverage are unchanged")
    pairs = load_json(os.path.join(DATA, "board-pairs.json"))
    corpus = load_json(os.path.join(DATA, "corpus-current.json"))
    log(f"device={DEVICE} commodities={len(defs)} board-pairs={len(pairs)} corpus={len(corpus)}")

    # SCORE CACHE (2026-08-22). Both model answers are pure functions of (model id, exact text), so they
    # are memoised on disk in out/embed-cache and only the texts this run has never seen reach the card.
    # A model is loaded lazily, on the first miss that needs it: a run on an unchanged shelf loads
    # neither and finishes in a few seconds instead of ~46 s, with a byte-identical findings file
    # (modulo generated/elapsed). See score_cache.py. SWEEP_CACHE=0 forces a cold, uncached run.
    if score_cache.enabled():
        m = score_cache.CachedScorer(
            CACHE, DEVICE,
            embed_factory=lambda: Matcher.load(with_reranker=False),
            rerank_factory=Matcher.load_reranker_only,
            embed_model=EMBED_MODEL, rerank_model=RERANK_MODEL)
    else:
        m = Matcher.load(with_reranker=True)
    defs_by_id = {d["id"]: d for d in defs}
    cids = [d["id"] for d in defs]
    cidx = {c: i for i, c in enumerate(cids)}
    ctexts = [commodity_text(d) for d in defs]
    cvecs = m.embed(ctexts)
    log(f"embedded {len(ctexts)} commodity definitions")

    # ---------------- LANE 1: IDENTITY ----------------
    pairs = [p for p in pairs if p["id"] in defs_by_id]
    pnames = [clean_product(p["product"]) for p in pairs]
    t0 = time.time()
    pvecs = m.embed(pnames)
    log(f"embedded {len(pnames)} shipped product names in {time.time()-t0:.1f}s")
    cos = torch.tensor([float(torch.dot(pvecs[i], cvecs[cidx[pairs[i]['id']]])) for i in range(len(pairs))])
    # Cross-encode only the weakest tail. Reranking all 2,816 costs 12 s and tells us nothing new about
    # the pairs that already look obviously right; the decision only ever concerns the bottom.
    # Rerank EVERY shipped pair, because the decision below is relative and needs the whole distribution.
    # 2,816 pairs costs about twelve seconds, which is nothing against getting the judgement right.
    ce_all = m.rerank([(pnames[i], ctexts[cidx[pairs[i]["id"]]]) for i in range(len(pairs))])

    # RELATIVE, NOT ABSOLUTE. The first full sweep used a global floor and flagged "Yellow Bananas" as a
    # suspicious instance of Bananas, alongside "Kroger Thin Spaghetti" for Pasta - all correct pairs.
    # The cause is not the model being wrong, it is the question being wrong: short generic product names
    # score low against every commodity, so an absolute bar just selects for short names.
    # The honest question is the one the basis-outlier audit asks about price: is this cell an outlier
    # AMONG ITS OWN PEERS? If all six banana products score 0.001, that is the commodity's baseline. If
    # five coconut-oil products score 0.9 and a bath soap scores 0.02, THAT is a defect.
    by_com: dict[str, list[int]] = {}
    for i, p in enumerate(pairs):
        by_com.setdefault(p["id"], []).append(i)
    identity = []
    for cid, idxs in by_com.items():
        if len(idxs) < 3:
            continue  # too few peers for a median to mean anything; silence beats a guess
        vals = sorted(ce_all[i] for i in idxs)
        med = vals[len(vals) // 2]
        if med < 0.05:
            continue  # the whole commodity scores low (short names): no peer signal to use
        for i in idxs:
            if ce_all[i] >= med * IDENTITY_PEER_RATIO:
                continue
            identity.append({
                "kind": "identity", "id": cid, "commodity": pairs[i]["commodity"],
                "store": pairs[i]["store"], "product": pairs[i]["product"],
                "cos": round(float(cos[i]), 4), "score": round(ce_all[i], 6),
                "peer_median": round(med, 4),
                "why": "shipped on the board but reads as a far poorer instance of this commodity than the same commodity's other stores",
            })
    identity.sort(key=lambda r: r["score"] / max(1e-9, r["peer_median"]))
    log(f"LANE identity: {len(identity)} shipped pair(s) below the floor")

    # ---------------- LANE 2: COVERAGE ----------------
    unmatched = [r for r in corpus if not r.get("rule_match")]
    log(f"LANE coverage: {len(unmatched)} products match no rule")
    unames = [clean_product(r["product"]) for r in unmatched]
    t0 = time.time()
    uvecs = m.embed(unames)
    log(f"embedded {len(unames)} rule-invisible products in {time.time()-t0:.1f}s")

    # best commodity per unmatched product, in chunks so VRAM stays bounded
    best_score = torch.full((len(unames),), -1.0)
    best_idx = torch.zeros(len(unames), dtype=torch.long)
    CH = 4096
    for s in range(0, len(unames), CH):
        blk = uvecs[s:s + CH] @ cvecs.T          # (chunk, commodities)
        v, a = torch.max(blk, dim=1)
        best_score[s:s + CH] = v.cpu()
        best_idx[s:s + CH] = a.cpu()
    cand = [i for i in range(len(unames)) if float(best_score[i]) >= COVERAGE_COS_FLOOR]
    log(f"  {len(cand)} candidate(s) above the cosine floor; cross-encoding")
    coverage = []
    if cand:
        ce2 = m.rerank([(unames[i], ctexts[int(best_idx[i])]) for i in cand])
        for k, i in enumerate(cand):
            if ce2[k] < COVERAGE_RERANK_FLOOR:
                continue
            cid = cids[int(best_idx[i])]
            coverage.append({
                "kind": "coverage", "id": cid, "commodity": defs_by_id[cid]["label"],
                "store": unmatched[i]["store"], "product": unmatched[i]["product"],
                "cos": round(float(best_score[i]), 4), "score": round(ce2[k], 6),
                "why": "no rule matches it, but it reads as an instance of this commodity",
            })
    coverage.sort(key=lambda r: -r["score"])
    log(f"LANE coverage: {len(coverage)} rule-invisible product(s) that look real")

    # ---------------- LANE 3: CONTESTED (phase 2, advisory + cache-warming) ----------------
    # The graph writes data/contested-pairs.json with `resolve.py --emit-contested`, read-only,
    # at the top of the nightly chain (graph/pipeline/nightly.ps1). Its absence is normal, not an
    # error: a run started by hand, or before the graph has ever emitted, simply skips this lane.
    helper = None
    if helper_path:
        # A SECOND CROSS-ENCODER, LANE 3 ONLY, AND THE PIN IS UNTOUCHED. RerankCache names its file
        # after the model id, so the helper's answers land beside the pinned model's and neither can
        # be mistaken for the other. Loaded lazily like everything else here: on a night where the
        # contested set has not changed, this costs no GPU at all.
        helper = score_cache.CachedScorer(
            CACHE, DEVICE,
            embed_factory=lambda: Matcher.load(with_reranker=False),
            rerank_factory=lambda: Matcher.load_reranker_only(helper_path),
            embed_model=EMBED_MODEL, rerank_model=helper_path)
        log(f"helper={helper_path} - LANE 3 ONLY; the sweep's own model is still {RERANK_MODEL}")
    cdefs_by_id = defs_by_id if cdefs is defs else {d["id"]: d for d in cdefs}
    contested_report = run_contested_lane(m, cdefs, cdefs_by_id, ctexts, cvecs, cidx, by_com, ce_all,
                                          defs_path=(contested_defs_path or defs_path),
                                          helper=helper, helper_id=helper_path or "")
    if helper is not None:
        helper.save()

    report = {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "device": DEVICE,
        "elapsed_sec": round(time.time() - t_start, 1),
        "thresholds": {
            "identity_peer_ratio": IDENTITY_PEER_RATIO,
            "coverage_cos_floor": COVERAGE_COS_FLOOR,
            "coverage_rerank_floor": COVERAGE_RERANK_FLOOR,
        },
        "examined": {"board_pairs": len(pairs), "corpus": len(corpus), "rule_invisible": len(unmatched)},
        "identity": identity,
        "coverage": coverage,
    }
    if contested_report is not None:
        report["contested"] = {k: v for k, v in contested_report.items() if k != "pairs"}
    if isinstance(m, score_cache.CachedScorer):
        m.save()
        report["cache"] = m.stats()
        log(f"cache: {report['cache']}")
    if contested_report is not None:
        cp = os.path.join(OUT, f"contested-scores{suffix}.json")
        tmp = cp + ".tmp"
        with open(tmp, "w", encoding="utf-8", newline="\n") as f:
            json.dump(contested_report, f, indent=2, ensure_ascii=False)
        os.replace(tmp, cp)
        log(f"wrote {cp}  ({contested_report['scored']} contested pair(s))")
    p = os.path.join(OUT, f"semantic-findings{suffix}.json")
    with open(p, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    log(f"wrote {p}  ({len(identity)} identity + {len(coverage)} coverage) in {report['elapsed_sec']}s")


if __name__ == "__main__":
    import argparse
    _ap = argparse.ArgumentParser(description="The nightly GPU batch (identity, coverage, contested)")
    _ap.add_argument("--defs", default=None,
                     help="commodity definitions to score against (default: data/commodity-defs.json). "
                          "graph/pipeline/emit_commodity_defs.py writes a graph-sourced one covering "
                          "BOTH namespaces.")
    _ap.add_argument("--tag", default="",
                     help="suffix the output files, so a comparison run cannot overwrite the "
                          "findings the daily alert de-dupes against. REQUIRED with --defs.")
    _ap.add_argument("--contested-defs", default=None,
                     help="definitions for LANE 3 ONLY. The contested questions come from the graph "
                          "and are 97%% recipe-namespace, which the staple catalogue cannot define; "
                          "identity and coverage keep --defs, so the daily alert does not move. "
                          "No --tag needed: this changes no file the alert reads.")
    _ap.add_argument("--helper", default=None,
                     help="a trained cross-encoder (sidecar/finetune_reranker.py) to score the "
                          "CONTESTED lane with, in its own cache, beside the pinned model's score. "
                          "Never replaces the pin and never touches identity or coverage.")
    _ap.add_argument("--selftest", action="store_true")
    _a = _ap.parse_args()
    if _a.selftest:
        raise SystemExit(_selftest())
    if _a.defs and not _a.tag:
        _ap.error("--tag is required with --defs, so a comparison run cannot overwrite the daily "
                  "findings (try --tag graphdefs)")
    main(defs_path=_a.defs, tag=_a.tag, contested_defs_path=_a.contested_defs,
         helper_path=_a.helper)
