"""
hardeval.py - re-measure the identity matcher on an eval set that contains SUBTLE errors.

WHY THIS EXISTS
---------------
Phase 1's backtest reported AUC 0.985 and that number was misleading. Its 25 labelled negatives are all
DRAMATICALLY wrong - a bath soap as coconut oil, dog food as meat - so it never asked the model a hard
question. When the identity lane then ran on the real board it flagged 173 pairs and every one inspected
was CORRECT: Wimmer's Wieners against Hot Dogs, Kroger Olive Oil Mayo against Mayonnaise, Yellow Bananas
against Bananas. Separating soap from oil says nothing about separating a wiener from a hot dog, and the
second question is the entire job.

So the first move is not a fine-tune, it is an honest eval. Two negative sets, and they measure different
things on purpose:

  GOLD   45 pairs expanded from the 63 adjudicated rulings in known-wrong.json. A reasoner looked at the
         product and the commodity and ruled they are not the same thing. These include the subtle shapes
         the old set had none of - sandwich cookies matched into FROSTING on the words "Butter Cream
         Icing", a ready-to-drink oat milk latte matched into COFFEE. This is the class the lane must
         catch.
  MINED  near-miss pairs: a real product, paired with a commodity that is semantically CLOSE to it but
         whose own regex rejects it. These are the class the lane must NOT flag, because in production
         almost every pair it scores is of this kind - similar, and fine.

The number that decides whether the lane can ship is not AUC. It is: at a threshold that catches most of
GOLD, how many accepted board pairs does it also flag? That is the false-alarm rate a human would have to
work through every day, and 173-a-day is the answer that stopped it shipping.

STAGES
------
  --stage mine   embed products + commodities, propose near-miss candidates, write mine-candidates.json
                 for PowerShell to stamp with the regex verdict (Python never re-implements the rules)
  --stage score  score positives + gold (+ mined, if labelled) and write the report

THIS FILE, NOT backtest.py, IS THE GATE A FINE-TUNE MUST CLEAR (2026-08-22)
---------------------------------------------------------------------------
    python sidecar/hardeval.py --stage score --reranker C:/path/to/candidate --tag ft-v1

PLAN-local-matching section 6 names backtest.py as the acceptance gate for a retrained
cross-encoder. That is the weaker of the two evals and this file is the reason it is weaker: on the
dramatic negatives the stock model looks like AUC 0.985, and on the adjudicated ones it is 0.864.
A candidate measured only against soap-as-coconut-oil can lose the wiener-vs-hot-dog cases and still
report an improvement. Run BOTH; treat the GOLD number here as the one that decides.

--reranker does not move the pin (see lib_match.Matcher._reranker), and --tag names the output so a
candidate cannot overwrite the stock baseline it is being compared against.
"""
from __future__ import annotations
import argparse, json, os, sys, time

import torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib_match import (Matcher, clean_product, commodity_text, load_json, DEVICE,
                       EMBED_MODEL, RERANK_MODEL)

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
OUT = os.path.join(HERE, "out")
os.makedirs(OUT, exist_ok=True)


def log(m: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


def auc(pos: list[float], neg: list[float]) -> float:
    """P(a random accepted pair scores above a random wrong pair). 0.5 = coin flip.

    Same tie-corrected implementation as backtest.py, copied deliberately rather than imported: the two
    reports are read side by side and a difference in the metric would be indistinguishable from a
    difference in the model.
    """
    if not pos or not neg:
        return float("nan")
    allv = sorted([(v, 0) for v in neg] + [(v, 1) for v in pos])
    ranks: dict[int, float] = {}
    i, r = 0, 1
    while i < len(allv):
        j = i
        while j + 1 < len(allv) and allv[j + 1][0] == allv[i][0]:
            j += 1
        avg = (r + (r + (j - i))) / 2.0
        for k in range(i, j + 1):
            ranks[k] = avg
        r += (j - i + 1)
        i = j + 1
    sr = sum(ranks[k] for k in range(len(allv)) if allv[k][1] == 1)
    n1, n0 = len(pos), len(neg)
    return (sr - n1 * (n1 + 1) / 2.0) / (n1 * n0)


def mined_rows_of(obj) -> list[dict]:
    """mine-candidates.json / mine-labelled.json, in either shape.

    The files were a bare list before they carried provenance. Both shapes are read rather than
    migrated, because a mined set is a record: an older one on someone's disk must still be
    readable, and the alternative is a builder that silently sees zero rows.
    """
    return obj.get("pairs", []) if isinstance(obj, dict) else list(obj)


def load_defs(path: str | None = None):
    """Today's commodity definitions, or a frozen snapshot.

    commodity_text() is label + today's accepted exemplars, so these definitions drift with the
    board and every score drifts with them. Measured 2026-08-22: dropping the exemplars moves TASK A
    AUC from 0.9705 to 0.7921. Any stock-vs-candidate comparison must pass the SAME frozen file to
    both sides (sidecar/freeze_eval.py), or it measures the shelf rather than the model.
    """
    p = path or os.path.join(DATA, "commodity-defs.json")
    defs = load_json(p)
    return defs, {d["id"]: d for d in defs}


def stage_mine(top_k: int, defs_path: str | None = None, margin: float = 0.08) -> None:
    """Propose the near-miss pairs. Bi-encoder only - no cross-encoder is loaded, and none is wanted:
    mining decides which pairs are WORTH labelling, and letting the model under test choose its own
    exam would be the same self-citation phase 1 took out of the resolver's memory.

    --defs matters here as much as it does in stage_score, and for a longer-lived reason. The mined
    negatives become part of the eval set and part of the training corpus, so a candidate list mined
    against today's drifting board would bake one morning's shelf into every later comparison.
    """
    prods = load_json(os.path.join(DATA, "mine-products.json"))
    defs, defs_by_id = load_defs(defs_path)
    m = Matcher.load(with_reranker=False)   # mining is bi-encoder only; no cross-encoder is loaded
    log(f"defs={defs_path or 'commodity-defs.json (today, drifts with the board)'}")
    log(f"device={DEVICE}  products={len(prods)}  commodities={len(defs)}")

    cids = [d["id"] for d in defs]
    cvecs = m.embed([commodity_text(d) for d in defs])
    names = [clean_product(p["product"]) for p in prods]
    t0 = time.time()
    pvecs = m.embed(names)
    log(f"embedded {len(names)} products in {time.time()-t0:.1f}s")

    sims = pvecs @ cvecs.T                       # (P, C) cosine, both already normalised
    k = min(top_k + 1, len(cids))                # +1 because the owner itself will usually rank first
    top = torch.topk(sims, k=k, dim=1)
    col = {c: j for j, c in enumerate(cids)}
    out, dropped_far, no_owner = [], 0, 0
    for i, p in enumerate(prods):
        owner = p["owner"]
        # THE PRODUCT'S OWN COMMODITY IS THE YARDSTICK, not a global floor. This corpus already
        # learned that short generic names ("Cantaloupe") score low against everything, so an
        # absolute bar just selects for short names. `Cantaloupe -> cornmeal` at 0.278 is a true
        # negative and not a near miss, and mining it would flatter the MINED AUC with easy rows.
        j = col.get(owner)
        ocos = float(sims[i][j]) if j is not None else None
        if ocos is None:
            no_owner += 1
        for rank in range(k):
            cid = cids[int(top.indices[i][rank])]
            if cid == owner:
                continue
            cos = float(top.values[i][rank])
            if ocos is not None and (ocos - cos) > margin:
                dropped_far += 1
                continue
            out.append({
                "product": p["product"], "owner": owner, "candidate": cid,
                "cos": round(cos, 4),
                "owner_cos": (round(ocos, 4) if ocos is not None else None),
                "delta": (round(ocos - cos, 4) if ocos is not None else None),
            })
    log(f"kept {len(out)} within {margin:.3f} cosine of the product's own commodity; "
        f"dropped {dropped_far} as too far to be a near miss"
        + (f"; {no_owner} product(s) have no definition for their own commodity" if no_owner else ""))
    path = os.path.join(DATA, "mine-candidates.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"generated": time.strftime("%Y-%m-%d %H:%M:%S"),
                   "defs": defs_path or "commodity-defs.json (today)",
                   "defs_frozen": bool(defs_path), "embed_model": EMBED_MODEL,
                   "top_k": top_k, "margin": margin, "dropped_too_far": dropped_far,
                   "products": len(prods), "commodities": len(defs),
                   "pairs": out}, f, indent=1)
    log(f"mine-candidates.json: {len(out)} near-miss candidate pair(s) -> label them with "
        f"export-identity-eval.ps1 -Label")


def score_pairs(m: Matcher, defs_by_id: dict, rows: list[dict], key_id: str = "id") -> list[float]:
    pairs, keep = [], []
    for r in rows:
        cid = r[key_id]
        d = defs_by_id.get(cid)
        if not d:
            continue
        # (QUERY, DOCUMENT) - product first, commodity second. This file had it the other way round
        # from the day it was written (fixed 2026-08-23). A cross-encoder is not symmetric, and the
        # reason the bug survived is that the STOCK model barely notices: GOLD 0.8312 reversed
        # against 0.8329 correct. A fine-tune notices enormously, because it learned one order and
        # only one - ft-v1 measured GOLD 0.6918 reversed and 0.9940 correct, so the reversed gate
        # would have rejected a candidate that beats the incumbent. Every other rerank call site in
        # the estate (backtest.py:160, all three sweep lanes, the training corpus's query/doc) is
        # product-first; this was the only one that was not.
        pairs.append((clean_product(r["product"]), commodity_text(d)))
        keep.append(r)
    scores = m.rerank(pairs)
    for r, s in zip(keep, scores):
        r["_score"] = float(s)
    return [r["_score"] for r in keep]


def operating_points(pos: list[float], neg: list[float], label: str) -> list[str]:
    """The only number that decides whether the lane ships: cost of catching the wrong ones.

    Reported as 'to catch N% of the wrong pairs, you must also review M accepted pairs', because that M
    is the human's daily workload and 173 was the answer that stopped this lane from shipping.
    """
    lines = []
    if not neg:
        return ["  (no negatives)"]
    sneg = sorted(neg)
    for frac in (0.50, 0.80, 0.90, 1.00):
        idx = min(len(sneg) - 1, int(round((1 - frac) * (len(sneg) - 1))))
        thr = sneg[idx]                      # flag everything scoring <= thr
        caught = sum(1 for v in neg if v <= thr)
        false_alarms = sum(1 for v in pos if v <= thr)
        rate = 100.0 * false_alarms / max(1, len(pos))
        lines.append(f"  catch {caught}/{len(neg)} {label} (thr {thr:.4f})"
                     f"  ->  {false_alarms} of {len(pos)} accepted pairs also flagged ({rate:.1f}%)")
    return lines


def holdout_families(corpus_dir: str) -> tuple[set[str], dict[str, str]]:
    """The corpus's held-out families, and which family each commodity is in.

    THE PROBLEM THIS EXISTS FOR (2026-08-23). eval-positives.json IS the accepted board pairs and
    negatives-gold.json IS the known-wrong rulings - both are training sources for section 6. So
    scoring a fine-tune on them is mostly IN-SAMPLE, and the prep addendum's ruling that "the GOLD
    number is the one that decides" is true of the stock baseline and not true of a candidate that
    trained on those rows. A candidate can memorise its way to a better GOLD AUC without having
    learned anything transferable.

    build_pair_corpus.py already holds out whole commodity FAMILIES, so the cold subset exists; it
    just was not reachable from here. The family map is read back off the corpus rows rather than
    recomputed from the graph, so the two can never disagree about which rows a model saw.
    """
    fam: dict[str, str] = {}
    for name in ("train.jsonl", "test.jsonl"):
        p = os.path.join(corpus_dir, name)
        if not os.path.exists(p):
            continue
        with open(p, encoding="utf-8") as f:
            for ln in f:
                if ln.strip():
                    r = json.loads(ln)
                    fam.setdefault(r["def_id"], r.get("family") or "uncategorised")
    mp = os.path.join(corpus_dir, "manifest.json")
    held = set(json.load(open(mp, encoding="utf-8")).get("holdout_families", [])) if os.path.exists(mp) else set()
    return held, fam


def stage_score(reranker: str | None = None, tag: str = "stock",
                defs_path: str | None = None, corpus_dir: str | None = None) -> None:
    defs, defs_by_id = load_defs(defs_path)
    log(f"defs={defs_path or 'commodity-defs.json (today, drifts with the board)'}")
    pos_rows = load_json(os.path.join(DATA, "eval-positives.json"))
    gold_rows = load_json(os.path.join(DATA, "negatives-gold.json"))
    old_rows = load_json(os.path.join(DATA, "negatives.json"))
    mined_rows = []
    mp = os.path.join(DATA, "mine-labelled.json")
    if os.path.exists(mp):
        mined_rows = [r for r in mined_rows_of(load_json(mp)) if not r.get("rules_accept")]

    held: set[str] = set()
    if corpus_dir:
        held, fam = holdout_families(corpus_dir)
        if not held:
            log(f"REFUSED: {corpus_dir} records no holdout families; a cold run cannot be built from it")
            raise SystemExit(2)

        def cold(rows, key="id"):
            return [r for r in rows if fam.get(r.get(key), "uncategorised") in held]

        pos_rows, gold_rows = cold(pos_rows), cold(gold_rows)
        old_rows = cold(old_rows)
        mined_rows = cold(mined_rows, key="candidate")
        log(f"COLD RUN: rows restricted to the held-out families ({', '.join(sorted(held))}). "
            f"Every pair here is one the corpus could not have shown the model.")

    m = Matcher.load(with_reranker=True, reranker_path=reranker)
    log(f"cross-encoder: {m.rerank_id}")
    log(f"device={DEVICE}  positives={len(pos_rows)}  gold={len(gold_rows)}  "
        f"old-negatives={len(old_rows)}  mined={len(mined_rows)}")

    t0 = time.time()
    pos = score_pairs(m, defs_by_id, pos_rows)
    gold = score_pairs(m, defs_by_id, gold_rows)
    old = score_pairs(m, defs_by_id, old_rows)
    mined = score_pairs(m, defs_by_id, mined_rows, key_id="candidate") if mined_rows else []
    log(f"scored {len(pos)+len(gold)+len(old)+len(mined)} pairs in {time.time()-t0:.1f}s")

    rep = []
    rep.append(f"# Identity matcher: the harder eval "
               f"({time.strftime('%Y-%m-%d')}, tag `{tag}`, defs "
               f"`{os.path.basename(os.path.dirname(defs_path)) if defs_path else 'today'}`)\n")
    rep.append("Phase 1 reported **AUC 0.985** on 25 negatives that are all dramatically wrong (bath soap,")
    rep.append("dog food). This re-measures the SAME model against negatives that are subtle.\n")
    rep.append(f"- accepted board pairs (positives): **{len(pos)}**")
    rep.append(f"- OLD negatives (Phase 1's set): **{len(old)}**")
    rep.append(f"- GOLD negatives (adjudicated wrong-product rulings): **{len(gold)}**")
    rep.append(f"- MINED near-miss negatives (rule-rejected, semantically close): **{len(mined)}**\n")
    rep.append("## AUC\n")
    rep.append(f"| negative set | n | AUC |")
    rep.append(f"|---|---:|---:|")
    rep.append(f"| Phase 1 (dramatic) | {len(old)} | {auc(pos, old):.4f} |")
    rep.append(f"| GOLD (adjudicated) | {len(gold)} | {auc(pos, gold):.4f} |")
    if mined:
        rep.append(f"| MINED (near miss)  | {len(mined)} | {auc(pos, mined):.4f} |")
    rep.append("")
    rep.append("## The number that decides shipping\n")
    rep.append("AUC is not it. The lane is advisory, so what matters is how many CORRECT pairs a human has")
    rep.append("to read in order to be shown the wrong ones.\n")
    rep.append("```")
    rep += operating_points(pos, old, "OLD")
    rep += operating_points(pos, gold, "GOLD")
    if mined:
        rep += operating_points(pos, mined, "MINED")
    rep.append("```\n")

    # ---- THE FAIR TEST. A raw threshold is not the design: lib_match calibrates PER COMMODITY, because
    # 0.005 means something different for Red Pepper Flakes than for Milk. Scoring a pair against its own
    # commodity's accepted distribution is the strongest form of the current architecture, so if the
    # inversion survives calibration it is not a scaling problem and no threshold will fix it.
    by_c: dict[str, list[float]] = {}
    for r in pos_rows:
        if "_score" in r:
            by_c.setdefault(r["id"], []).append(r["_score"])

    def z(r, cid_key="id"):
        """How far below its OWN commodity's accepted median this pair sits, in median-absolute-deviations.
        Robust on purpose: several commodities have a handful of exemplars and one outlier would set a
        mean-based floor wherever it liked."""
        v = by_c.get(r[cid_key]) or []
        if len(v) < 3:
            return None
        s = sorted(v)
        med = s[len(s) // 2]
        mad = sorted(abs(x - med) for x in s)[len(s) // 2] or 1e-6
        return (r["_score"] - med) / mad

    zpos = [x for x in (z(r) for r in pos_rows if "_score" in r) if x is not None]
    zgold = [x for x in (z(r) for r in gold_rows if "_score" in r) if x is not None]
    rep.append("## Calibrated per commodity (the fair test)\n")
    rep.append("Each pair scored against its OWN commodity's accepted distribution, which is what")
    rep.append("lib_match's `calibrate` exists to do. If the answer does not improve here, the problem is")
    rep.append("not the threshold.\n")
    rep.append(f"- scorable positives {len(zpos)} / gold {len(zgold)} (a commodity needs 3+ accepted")
    rep.append("  products before it has a distribution to calibrate against)")
    if zpos and zgold:
        rep.append(f"- AUC on the calibrated score: **{auc(zpos, zgold):.4f}**\n")
        rep.append("```")
        rep += operating_points(zpos, zgold, "GOLD (calibrated)")
        rep.append("```\n")

    worst = sorted([r for r in gold_rows if "_score" in r], key=lambda r: -r["_score"])[:10]
    rep.append("## The adjudicated-wrong pairs the model likes MOST\n")
    rep.append("These are the ones it would never flag. Each is a product a reasoner ruled is not the")
    rep.append("commodity, scored as if it belongs. **Read the list before deciding what to fine-tune**:")
    rep.append("they are not one failure, they are two, and only one of them is learnable from a name.")
    rep.append("")
    rep.append("- CARRIER errors (the commodity is an INGREDIENT inside a different product): Parmesan")
    rep.append("  Garlic Pita Chips as parmesan, a chicken sausage with sun-dried tomatoes as sun-dried")
    rep.append("  tomatoes. A model can learn these, and more labelled examples would help.")
    rep.append("- SPECIFICATION errors (right product family, wrong grade or cut): Roast Beef Hash against")
    rep.append("  corned-beef-hash, 96% lean against ground-beef-93-7, Pork Half Loin against")
    rep.append("  pork-tenderloin, a beef-and-pork blend against ground-pork. Nothing in the NAME says")
    rep.append("  which grade a commodity wants - that fact lives in the commodity's own definition, not")
    rep.append("  in the product string - so no amount of fine-tuning on names will separate them. These")
    rep.append("  need a grade/cut check, which is a different mechanism.")
    rep.append("")
    rep.append("One caveat on the gold set itself: `ground-cloves <- Spice Supreme Spice Ground Cloves` is")
    rep.append("in the blocklist as a PRICE defect, not an identity one. The product IS ground cloves. The")
    rep.append("model scoring it 0.531 is correct behaviour counted as a miss, so treat 45 as the")
    rep.append("pessimistic denominator.")
    rep.append("")
    for r in worst:
        rep.append(f"- `{r['_score']:.3f}`  **{r['id']}**  <- {r['product'][:90]}")
    rep.append("")
    best_pos = sorted([r for r in pos_rows if "_score" in r], key=lambda r: r["_score"])[:10]
    rep.append("## The accepted pairs the model likes LEAST\n")
    rep.append("The false alarms a low threshold buys. If these read as obviously fine, the lane is")
    rep.append("flagging correctness, not error.\n")
    for r in best_pos:
        rep.append(f"- `{r['_score']:.3f}`  **{r['id']}**  <- {r['product'][:90]}")
    rep.append("")

    suffix = "" if tag == "stock" else f"-{tag}"
    path = os.path.join(OUT, f"hardeval-report{suffix}.md")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(rep))
    json.dump(
        # WHICH MODEL SAID THIS. Without it, two reports on this box are indistinguishable the
        # moment a second copy of the reranker exists - which is the premise of section 6.
        {"tag": tag, "embed_model": EMBED_MODEL, "rerank_model": m.rerank_id,
         "is_pinned_model": (m.rerank_id == RERANK_MODEL),
         "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
         "positives": len(pos), "old": len(old), "gold": len(gold), "mined": len(mined),
         "holdout_only": sorted(held) if held else None,
         "auc_old": auc(pos, old), "auc_gold": auc(pos, gold),
         "auc_mined": (auc(pos, mined) if mined else None)},
        open(os.path.join(OUT, f"hardeval{suffix}.json"), "w", encoding="utf-8"), indent=2)
    print("\n".join(rep))
    log(f"wrote {path}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--stage", choices=["mine", "score"], required=True)
    ap.add_argument("--top-k", type=int, default=8)
    ap.add_argument("--margin", type=float, default=0.08,
                    help="mine a candidate only when it scores within this cosine of the product's "
                         "OWN commodity. Relative, not absolute: see stage_mine().")
    ap.add_argument("--reranker", default=None,
                    help="path to a candidate cross-encoder to score with INSTEAD of the pinned "
                         "model, for this run only. Does not change the pin or affect sweep.py.")
    ap.add_argument("--tag", default=None,
                    help="suffix for the output files. Defaults to 'stock' for a pinned run and is "
                         "REQUIRED with --reranker, so a candidate cannot overwrite the baseline.")
    ap.add_argument("--holdout-from", default=None, metavar="CORPUS_DIR",
                    help="restrict every set to the commodity families that corpus held out, so a "
                         "fine-tune is measured on rows it cannot have seen. See holdout_families(): "
                         "without this, a candidate trained on the board pairs and the known-wrong "
                         "rulings is being scored on its own training data.")
    ap.add_argument("--defs", default=None,
                    help="a FROZEN commodity-defs.json to score against instead of today's. Required "
                         "in practice for any before/after: see load_defs().")
    a = ap.parse_args()
    tag = a.tag or ("stock" if not a.reranker else None)
    if tag is None:
        ap.error("--tag is required with --reranker (try --tag ft-v1)")
    if a.stage == "mine":
        stage_mine(a.top_k, defs_path=a.defs, margin=a.margin)
    else:
        stage_score(reranker=a.reranker, tag=tag, defs_path=a.defs, corpus_dir=a.holdout_from)
