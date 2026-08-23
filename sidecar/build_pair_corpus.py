"""build_pair_corpus.py - the training corpus for a fine-tuned cross-encoder (PLAN-local-matching §6).

    python sidecar/build_pair_corpus.py --out sidecar/data/pair-corpus
    python sidecar/build_pair_corpus.py --holdout meat,dairy,oils --dry-run

Emits (query, doc, label) triples: `query` is a cleaned product name, `doc` is the commodity's
natural-language text, `label` is 1 for "this product IS an instance of this commodity" and 0 for
"it is not". That is precisely the question the sweep's cross-encoder answers, so the corpus and the
model speak the same language.

NOT TO BE CONFUSED WITH tools/local-llm/finetune-probe/build_corpus.py, which builds prompt ->
completion JSONL for the 27B (plan §10). Different model, different task, different file format.
Neither is reusable as the other.

WHAT GOES IN, AND WHAT IS DELIBERATELY LEFT OUT
-----------------------------------------------
  positives   gold MATCH; the accepted pairs the board ships (`instance_of`); adjudicated
              `llm_confirmed` (a Claude reviewer said yes)
  negatives   gold NO_MATCH; the known-wrong rulings; adjudicated `llm_rejected`

  LEFT OUT: the ~3,300 SINGLE-MODEL rejections. Phase 1 stopped citing those to the local model as
  precedent because a wrong rejection was becoming the reason to reject its neighbours. Training the
  helper on them is the same disease with a worse prognosis: retrieval can be changed, weights
  cannot, so the loop would be baked in where nothing could undo it. It is also what makes §4's
  audit row honest - the helper's verdict on those rows stays genuinely out-of-sample, which is the
  only reason disagreement there means anything.

  The cost of that principle is worth stating plainly: it leaves roughly 1,100 hard negatives
  against roughly 4,500 positives, a 4:1 imbalance the training run has to handle deliberately
  (class weights or negative oversampling) rather than by accident.

  ALSO MISSING, AND IT MATTERS MOST: near-miss negatives - a real product paired with a commodity
  that is semantically close but whose own regex rejects it. hardeval.py mines them and the labelled
  file has never been produced (`mined: 0` in every report to date). That is the class the helper
  will actually meet: on the contested set, nearly every pair is similar-and-wrong or
  similar-and-right. A corpus without them teaches soap-is-not-coconut-oil, which the stock model
  already knows. Run `hardeval.py --stage mine` + `export-identity-eval.ps1 -Label` before training,
  and this builder will pick the result up automatically.

THE HOLDOUT IS BY COMMODITY FAMILY, NOT BY ROW
-----------------------------------------------
A random row split would put "Kroger Ground Cumin" in train and "Tone's Ground Cumin" in test, and
the score would measure memorisation. Holding out whole families makes the test COLD BY
CONSTRUCTION - the same standard phase 1 held the bench to, and the reason its honest baseline came
out at 0.79 rather than 0.900.

Families come from the graph's own `in_category` edges (16 categories). 99 of 687 commodities carry
no category; they form a family called `uncategorised`, which is a real bucket and is reported as
such rather than silently dropped or silently trained on.

DOC TEXT COMES FROM A FROZEN SNAPSHOT BY DEFAULT
-------------------------------------------------
`commodity_text()` is label + today's accepted exemplars, so it drifts with the shelf (measured
2026-08-22: dropping the exemplars moves TASK A AUC from 0.9705 to 0.7921). A corpus built on
Tuesday and a baseline measured on Thursday are not comparable. So this reads the newest frozen
snapshot under data/frozen/ unless told otherwise, and records which one in the manifest.

READ-ONLY on the graph, enforced with PRAGMA query_only.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import sqlite3
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DATA = os.path.join(HERE, "data")
FROZEN = os.path.join(DATA, "frozen")

sys.path.insert(0, HERE)
from lib_match import clean_product, commodity_text, load_json    # noqa: E402

sys.path.insert(0, os.path.join(REPO, "graph", "lib"))
sys.path.insert(0, os.path.join(REPO, "graph", "gold"))


def log(m: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


def open_ro(path: str) -> sqlite3.Connection:
    uri = "file:" + os.path.abspath(path).replace("\\", "/") + "?mode=ro"
    c = sqlite3.connect(uri, uri=True)
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA query_only = ON")
    return c


def newest_frozen() -> str | None:
    if not os.path.isdir(FROZEN):
        return None
    cands = [d for d in sorted(os.listdir(FROZEN))
             if os.path.exists(os.path.join(FROZEN, d, "commodity-defs.json"))]
    if not cands:
        return None
    return os.path.join(FROZEN, cands[-1], "commodity-defs.json")


def bare(cid: str) -> str:
    """`commodity:staple:cumin` -> `cumin`. The graph namespaces its node ids and
    grocery/commodities.json (which builds commodity-defs.json) does not."""
    return cid.rsplit(":", 1)[-1]


def collect(conn: sqlite3.Connection, defs_by_id: dict) -> tuple[list[dict], dict]:
    """Every labelled pair the estate owns, with its provenance attached.

    `source` rides along on every row on purpose. If the trained model turns out to have learned
    something odd, the first question is always "which pile taught it that", and a corpus that
    cannot answer it has to be rebuilt to find out.
    """
    sys.path.insert(0, os.path.join(REPO, "graph", "lib"))
    from authority import authority_tier                                       # noqa: PLC0415

    rows: list[dict] = []
    stats: dict[str, int] = {}

    def add(cid: str, product: str, label: int, source: str) -> None:
        d = defs_by_id.get(bare(cid))
        if not d or not product:
            stats[f"skipped:{source}:no-definition"] = stats.get(f"skipped:{source}:no-definition", 0) + 1
            return
        rows.append({"commodity_id": cid, "def_id": bare(cid),
                     "query": clean_product(product), "doc": commodity_text(d),
                     "label": label, "source": source, "product_raw": product})
        stats[source] = stats.get(source, 0) + 1

    # -- the gold set: the estate's own labelled evaluation cases
    try:
        from seed_gold import load_gold                                        # noqa: PLC0415
        for g in load_gold():
            if g.get("kind") != "match":
                continue
            lbl = 1 if g.get("label") == "MATCH" else 0
            add(g.get("commodity_node") or "", g.get("product") or "", lbl,
                "gold_match" if lbl else "gold_no_match")
    except Exception as e:                                                     # noqa: BLE001
        log(f"WARNING gold set unavailable ({e}) - the corpus is missing its cleanest labels")
        stats["error:gold"] = 1

    # -- what the board ships: the largest positive pile, and real supervision we already own
    for r in conn.execute(
            """SELECT e.target_id AS cid, n.canonical_name AS product
               FROM edges e JOIN nodes n ON n.id = e.source_id
               WHERE e.predicate = 'instance_of'"""):
        add(r["cid"], r["product"] or "", 1, "accepted_pair")

    # -- adjudicated verdicts only. The tier, not the status, decides: state.py derived decided_by
    #    from the status prefix until phase 1, so a Claude reviewer's ruling was stamped 'model' too.
    for r in conn.execute(
            """SELECT commodity_id, product_name, status, reason, decided_by
               FROM question_verdicts
               WHERE status IN ('llm_rejected','llm_confirmed','known_wrong')"""):
        tier = authority_tier(r["status"], r["reason"], r["decided_by"])
        if tier != "adjudicated":
            stats["excluded:single_model"] = stats.get("excluded:single_model", 0) + 1
            continue
        lbl = 1 if r["status"] == "llm_confirmed" else 0
        add(r["commodity_id"], r["product_name"] or "", lbl, f"adjudicated_{r['status']}")

    # -- the known-wrong nodes: absolute negatives, adjudicated with written evidence
    for r in conn.execute(
            """SELECT n.id AS cid, k.canonical_name AS product
               FROM nodes k JOIN edges e ON e.source_id = k.id AND e.predicate = 'known_wrong_for'
               JOIN nodes n ON n.id = e.target_id
               WHERE k.type = 'KnownWrong'"""):
        add(r["cid"], r["product"] or "", 0, "known_wrong")

    # -- mined near-misses, if anyone has labelled them yet (see the header)
    mp = os.path.join(DATA, "mine-labelled.json")
    if os.path.exists(mp):
        for r in load_json(mp):
            if r.get("rules_accept"):
                continue
            add(r.get("candidate") or "", r.get("product") or "", 0, "mined_near_miss")
    else:
        stats["missing:mined_near_miss"] = 1

    return rows, stats


def families(conn: sqlite3.Connection) -> dict[str, str]:
    """commodity id -> family. The graph's own categories; everything else is `uncategorised`."""
    fam = {}
    for r in conn.execute(
            "SELECT source_id, target_id FROM edges WHERE predicate = 'in_category'"):
        fam.setdefault(r["source_id"], r["target_id"].rsplit(":", 1)[-1])
    for r in conn.execute("SELECT id FROM nodes WHERE type = 'Commodity'"):
        fam.setdefault(r["id"], "uncategorised")
    return fam


def main() -> int:
    ap = argparse.ArgumentParser(description="Build the cross-encoder training corpus")
    ap.add_argument("--out", default=os.path.join(DATA, "pair-corpus"))
    ap.add_argument("--db", default=os.path.join(REPO, "graph", "sqlite", "graph.db"))
    ap.add_argument("--defs", default=None,
                    help="commodity-defs.json to build doc text from (default: the newest frozen "
                         "snapshot, else today's - see the header on why frozen matters)")
    ap.add_argument("--holdout", default=None,
                    help="comma-separated families to hold out (default: a seeded random pick "
                         "covering ~20%% of the labelled rows)")
    ap.add_argument("--seed", type=int, default=20260822)
    ap.add_argument("--dry-run", action="store_true", help="report the split, write nothing")
    args = ap.parse_args()

    defs_path = args.defs or newest_frozen() or os.path.join(DATA, "commodity-defs.json")
    log(f"defs={defs_path}")
    if not os.path.exists(defs_path):
        log("BLIND: no commodity definitions; run grocery\\audit-semantic-identity.ps1 -PrepareOnly")
        return 3
    if not os.path.exists(args.db):
        log(f"BLIND: no graph db at {args.db}")
        return 3
    defs_by_id = {d["id"]: d for d in load_json(defs_path)}

    conn = open_ro(args.db)
    try:
        rows, stats = collect(conn, defs_by_id)
        fam = families(conn)
    finally:
        conn.close()

    # -- CONTRADICTIONS ARE REPORTED, NEVER RESOLVED SILENTLY. The same pair labelled both ways is
    #    either a ruling that changed or a mistake, and a builder that quietly picks one teaches the
    #    model whichever it happened to pick. Drop them and say how many.
    by_pair: dict[tuple[str, str], set[int]] = {}
    for r in rows:
        by_pair.setdefault((r["commodity_id"], r["query"]), set()).add(r["label"])
    conflicted = {k for k, v in by_pair.items() if len(v) > 1}
    if conflicted:
        log(f"WARNING {len(conflicted)} pair(s) carry BOTH labels - dropped, not guessed at")

    seen: set[tuple[str, str]] = set()
    kept = []
    for r in rows:
        k = (r["commodity_id"], r["query"])
        if k in conflicted or k in seen:
            continue
        seen.add(k)
        r["family"] = fam.get(r["commodity_id"], "uncategorised")
        kept.append(r)

    # -- the holdout, by family
    fam_rows: dict[str, int] = {}
    for r in kept:
        fam_rows[r["family"]] = fam_rows.get(r["family"], 0) + 1
    if args.holdout:
        held = [f.strip() for f in args.holdout.split(",") if f.strip()]
        unknown = [f for f in held if f not in fam_rows]
        if unknown:
            log(f"WARNING held-out family/families not present: {', '.join(unknown)}")
    else:
        rnd = random.Random(args.seed)
        order = sorted(fam_rows, key=lambda f: (-fam_rows[f], f))
        rnd.shuffle(order)
        target, acc, held = 0.20 * len(kept), 0, []
        for f in order:
            if acc >= target:
                break
            held.append(f)
            acc += fam_rows[f]
    held_set = set(held)

    train = [r for r in kept if r["family"] not in held_set]
    test = [r for r in kept if r["family"] in held_set]

    def bal(rs):
        p = sum(1 for r in rs if r["label"] == 1)
        return p, len(rs) - p

    tp, tn = bal(train)
    hp, hn = bal(test)
    log(f"rows {len(kept)} (from {len(rows)} raw, {len(conflicted)} conflicted dropped)")
    log(f"  train {len(train):>6}  +{tp} / -{tn}")
    log(f"  test  {len(test):>6}  +{hp} / -{hn}   families: {', '.join(sorted(held_set))}")
    for k in sorted(stats):
        log(f"    {k:<40} {stats[k]}")
    if hn == 0 or tn == 0:
        log("WARNING a split with no negatives cannot measure anything - choose --holdout by hand")

    if args.dry_run:
        log("dry run; nothing written")
        return 0

    os.makedirs(args.out, exist_ok=True)
    for name, rs in (("train.jsonl", train), ("test.jsonl", test)):
        p = os.path.join(args.out, name)
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            for r in rs:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        log(f"wrote {p} ({len(rs)} rows)")

    manifest = {
        "generated": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "defs": os.path.relpath(defs_path, REPO).replace("\\", "/"),
        "defs_frozen": os.path.abspath(defs_path).startswith(os.path.abspath(FROZEN)),
        "seed": args.seed,
        "holdout_families": sorted(held_set),
        "counts": {"raw": len(rows), "conflicted_dropped": len(conflicted), "kept": len(kept),
                   "train": {"pos": tp, "neg": tn}, "test": {"pos": hp, "neg": hn}},
        "sources": stats,
        "excluded_by_design": "single-model rejections (see the module header)",
    }
    mp = os.path.join(args.out, "manifest.json")
    with open(mp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(manifest, f, indent=2)
    log(f"wrote {mp}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
