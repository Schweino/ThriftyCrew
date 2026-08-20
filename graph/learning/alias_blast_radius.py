"""Blast radius for a proposed include-alias — the evidence the shadow gate cannot see.

    python graph/learning/alias_blast_radius.py             # every proposed add_alias
    python graph/learning/alias_blast_radius.py --proposal lp:xxxx
    python graph/learning/alias_blast_radius.py --pattern 'foo\\s+bar' --target commodity:staple:x

WHY THIS EXISTS. Stage 2 shadow-evaluates an accepted patch against the gold set
and drops anything that regresses. That is a real gate, but it has a blind spot
that became load-bearing on 2026-08-20, when the confirm-match review filed 116
include-alias proposals: **each alias was derived from the very gold case it
would then be scored against.** The shadow run therefore says "no regression"
for a reason that has nothing to do with safety — the one case it can see is the
case the pattern was written from. Circular evidence is not evidence.

What the gold set genuinely cannot see is the rest of the corpus. So this module
sweeps the candidate pattern over EVERY DISTINCT product name the estate has
ever captured (~30k strings, seconds) and reports what it would newly touch.
That is the non-circular half of the picture, and it is what makes a human (or
Fable) review of an alias meaningful.

THE FIVE BUCKETS, and why two of them are automatic kills:

  intended_capture  a name of this commodity the alias would newly settle. The
                    alias doing its job.

  absorbs_review    the name prices this commodity ONLY because a reviewer
                    confirmed it (llm_confirmed, no include hit). Also the alias
                    doing its job — this is precisely the hand-off the plan's
                    §5.2 asks for, moving a judgement out of the review queue and
                    into the deterministic layers so the model is never asked
                    again. Kept distinct from already_matched because collapsing
                    the two made 85 of 119 post-review aliases read as "captures
                    nothing new" when they were the entire point.

  already_matched   an include pattern ALREADY hits this name for this commodity.
                    Genuine redundancy — harmless, but not a reason to accept.

  cross_commodity   the name is currently PRICED under a DIFFERENT commodity.
                    Danger: layer 4 is first-hit-wins per commodity, so this
                    alias lets its commodity lay claim to a product another cell
                    is already pricing. The one benign class is the recipe-vs-
                    staple namespace twin (`commodity:recipe:ginger` and
                    `commodity:staple:fresh-ginger` legitimately price the same
                    jar), so those are separated out rather than counted as hits.

  known_wrong_hit   KILL. The name is adjudicated known-wrong for some commodity,
                    or is a gold NO_MATCH case. An include pattern that matches
                    an adjudicated negative is a pattern that re-litigates a
                    ruling, and rulings are absolute in this estate.

  rejected_hit      KILL, and the subtle one. The name was REJECTED for this
                    very commodity — by the reviewer or by the local model.
                    Include (layer 4) runs BEFORE the model (layer 5) ever gets
                    asked, so shipping this alias would resurrect a rejected
                    candidate and silently outrank the rejection on the next
                    re-import. A rejection is a decision; an alias must never
                    quietly reverse one.

This module DECIDES NOTHING. It writes evidence into
graph/learning/alias-blast-radius.json and stamps kill flags; the verdict is
still Stage 2's, and application is still `stage2_review.py --apply` with its
gold-set shadow gate intact. Advisory tooling that also enforced would be a
second, unreviewable gate.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
sys.path.insert(0, os.path.join(HERE, "..", "gold"))

from graphdb import open_db, GRAPH_DIR, read_json, REPO_ROOT   # noqa: E402
from ids import norm_text                                      # noqa: E402
from seed_gold import load_gold                                # noqa: E402

REPORT = os.path.join(GRAPH_DIR, "learning", "alias-blast-radius.json")

# Statuses that mean "this row is pricing, or could price, a cell for its
# commodity" — the ones a cross-commodity collision actually matters for.
PRICING = ("include_hit", "llm_confirmed")
# Statuses that mean "somebody said NO for this commodity".
REJECTED = ("llm_rejected", "known_wrong")

# How many example names to keep per bucket. Enough to judge, few enough to read.
EXAMPLES = 20


def _namespace_twin(a: str, b: str) -> bool:
    """True when two commodity ids are the same slug across namespaces, or an
    obvious staple/recipe pairing of the same food. Those legitimately share a
    product (the board prices a jar of ginger in both the staple row and the
    recipe row), so a collision between them is not a defect."""
    if a == b:
        return True
    sa, sb = a.rpartition(":")[2], b.rpartition(":")[2]
    if sa == sb:
        return True
    # fresh-ginger vs ginger, canned-white-beans vs cannellini-beans style pairs
    # are only twins if one slug contains the other as a whole token run.
    ta, tb = set(sa.split("-")), set(sb.split("-"))
    return bool(ta) and bool(tb) and (ta <= tb or tb <= ta)


def _load_corpus(db) -> list[tuple[str, dict]]:
    """Every distinct product name, with what the estate currently believes about
    it. Keyed by name; the value records which commodities price it and which
    have rejected it."""
    rows = db.conn.execute(
        """SELECT product_name, commodity_id, match_status, COUNT(*) n
           FROM price_observations
           WHERE product_name IS NOT NULL AND product_name != ''
           GROUP BY product_name, commodity_id, match_status""").fetchall()
    corpus: dict[str, dict] = {}
    for r in rows:
        e = corpus.setdefault(r["product_name"], {"priced_by": set(), "rejected_by": set(),
                                                  "rule_matched_by": set(), "rows": 0})
        e["rows"] += r["n"]
        if r["match_status"] in PRICING:
            e["priced_by"].add(r["commodity_id"])
            # Tracked separately from priced_by: a row priced ONLY because a
            # reviewer confirmed it is exactly what an alias is supposed to
            # absorb, while a row the include patterns already hit is genuine
            # redundancy. Collapsing the two makes every post-review alias look
            # like noise (measured: 85 of 119 on the first run).
            if r["match_status"] == "include_hit":
                e["rule_matched_by"].add(r["commodity_id"])
        elif r["match_status"] in REJECTED:
            e["rejected_by"].add(r["commodity_id"])
    return list(corpus.items())


def _load_negatives() -> dict[str, set[str]]:
    """Adjudicated negatives, normalised and **scoped to the commodity that ruled
    them** — keyed by commodity slug.

    Scoping is not cosmetic, and getting it wrong is not a small error. A product
    is routinely a negative for one commodity and perfectly correct for another:
    known-wrong.json's own header gives "Lysol Toilet Bowl Cleaner Clinging Gel",
    BLOCKED as stain-remover and CORRECT as toilet-bowl-cleaner. A first cut of
    this module matched negatives globally and produced four false kills in nine
    on the first real run — it rejected the fresh-thyme alias because "Local Roots
    Organic Thyme" is known-wrong for DRIED-thyme, and the maple-syrup alias
    because "Pearl Milling Butter Rich Syrup" is known-wrong for BUTTER. Both
    aliases were right; the tool was wrong.
    """
    neg: dict[str, set[str]] = defaultdict(set)
    path = os.path.join(REPO_ROOT, "grocery", "known-wrong.json")
    if os.path.exists(path):
        try:
            for e in (read_json(path).get("entries") or []):
                cslug = e.get("commodity")
                if not cslug:
                    continue
                for nm in (e.get("names") or []):
                    if nm:
                        neg[cslug].add(norm_text(nm))
        except (ValueError, OSError):
            pass
    for g in load_gold():
        if g.get("label") == "NO_MATCH" and g.get("product") and g.get("commodity"):
            neg[g["commodity"]].add(norm_text(g["product"]))
    return neg


def analyse(db, target: str, pattern: str, corpus=None, negatives=None) -> dict:
    """Sweep one candidate pattern over the corpus and bucket every hit."""
    corpus = corpus if corpus is not None else _load_corpus(db)
    neg = negatives if negatives is not None else _load_negatives()
    # Only THIS commodity's adjudicated negatives can kill this commodity's alias.
    own_negatives = neg.get(target.rpartition(":")[2], set())

    try:
        rx = re.compile(pattern, re.IGNORECASE)
    except re.error as e:
        return {"target": target, "pattern": pattern, "compile_error": str(e),
                "kill": True, "kill_reasons": [f"pattern does not compile: {e}"]}

    buckets: dict[str, list[dict]] = defaultdict(list)
    counts: dict[str, int] = defaultdict(int)

    for name, info in corpus:
        if not rx.search(name):
            continue
        n = norm_text(name)
        priced_by, rejected_by = info["priced_by"], info["rejected_by"]

        if n in own_negatives:
            bucket = "known_wrong_hit"
        elif target in rejected_by:
            bucket = "rejected_hit"
        elif target in info["rule_matched_by"]:
            bucket = "already_matched"          # an include pattern already hits it
        elif target in priced_by:
            bucket = "absorbs_review"           # priced only by a reviewer CONFIRM
        else:
            others = [c for c in priced_by if not _namespace_twin(target, c)]
            if others:
                bucket = "cross_commodity"
            else:
                bucket = "intended_capture"

        counts[bucket] += 1
        if len(buckets[bucket]) < EXAMPLES:
            rec = {"product": name[:90], "rows": info["rows"]}
            if bucket == "cross_commodity":
                rec["priced_by"] = sorted(priced_by)
            buckets[bucket].append(rec)

    kill_reasons = []
    if counts["known_wrong_hit"]:
        kill_reasons.append(
            f"matches {counts['known_wrong_hit']} name(s) adjudicated negative FOR "
            f"THIS COMMODITY (known-wrong or gold NO_MATCH) — an include pattern "
            f"may not re-litigate a ruling")
    if counts["rejected_hit"]:
        kill_reasons.append(
            f"matches {counts['rejected_hit']} name(s) REJECTED for this very "
            f"commodity — include runs before the model, so this would silently "
            f"reverse those rejections on the next re-import")

    warn_reasons = []
    if counts["cross_commodity"]:
        warn_reasons.append(
            f"matches {counts['cross_commodity']} name(s) already priced under a "
            f"different commodity — confirm the collision is benign before accepting")
    if not (counts["intended_capture"] or counts["absorbs_review"]):
        warn_reasons.append(
            "captures nothing new — it settles no unmatched row and absorbs no "
            "reviewer confirmation, so it is noise")

    return {
        "target": target,
        "pattern": pattern,
        "counts": {k: counts[k] for k in
                   ("intended_capture", "absorbs_review", "already_matched",
                    "cross_commodity", "known_wrong_hit", "rejected_hit")},
        "total_hits": sum(counts.values()),
        "kill": bool(kill_reasons),
        "kill_reasons": kill_reasons,
        "warn_reasons": warn_reasons,
        "examples": {k: v for k, v in buckets.items()},
    }


def analyse_proposals(db, only: str | None = None) -> dict:
    """Blast-radius every proposed add_alias (or just one)."""
    q = ("SELECT id, target_id, payload_json FROM learning_proposals "
         "WHERE kind='add_alias' AND status='proposed'")
    args: list = []
    if only:
        q += " AND id=?"
        args.append(only)
    rows = db.conn.execute(q + " ORDER BY target_id", args).fetchall()

    corpus = _load_corpus(db)
    negatives = _load_negatives()

    sys.path.insert(0, os.path.join(HERE, "..", "learning"))
    from stage2_review import resolve_target            # noqa: E402

    out: dict[str, dict] = {}
    for r in rows:
        payload = json.loads(r["payload_json"] or "{}").get("payload")
        if not payload:
            continue
        target = resolve_target(db, r["target_id"]) or r["target_id"]
        res = analyse(db, target, payload, corpus=corpus, negatives=negatives)
        res["proposal_id"] = r["id"]
        res["target_declared"] = r["target_id"]
        res["target_resolved"] = target if target != r["target_id"] else target
        out[r["id"]] = res
    return out


def write_report(report: dict) -> str:
    os.makedirs(os.path.dirname(REPORT), exist_ok=True)
    with open(REPORT, "w", encoding="utf-8", newline="\n") as fh:
        json.dump({"generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                   "proposals": report}, fh, indent=2, ensure_ascii=False)
    return REPORT


def main() -> int:
    ap = argparse.ArgumentParser(description="Blast radius for proposed include aliases")
    ap.add_argument("--proposal", help="only this proposal id")
    ap.add_argument("--pattern", help="ad-hoc: analyse this pattern instead of stored proposals")
    ap.add_argument("--target", help="commodity id for --pattern")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    ts = time.strftime("%Y-%m-%dT%H:%M:%S")
    run = f"run:blast-radius:{time.strftime('%Y%m%dT%H%M%S')}"

    with open_db() as db:
        if args.pattern:
            if not args.target:
                print("--pattern requires --target", file=sys.stderr)
                return 2
            res = analyse(db, args.target, args.pattern)
            print(json.dumps(res, indent=2, ensure_ascii=False))
            return 0

        report = analyse_proposals(db, only=args.proposal)
        path = write_report(report)
        kills = [r for r in report.values() if r.get("kill")]
        warns = [r for r in report.values() if r.get("warn_reasons") and not r.get("kill")]
        db.log_event(run=run, timestamp=ts, etype="learning_proposal",
                     decision="blast_radius",
                     detail={"analysed": len(report), "kill": len(kills),
                             "warn": len(warns)})

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return 0

    print(f"blast radius: {len(report)} proposed alias(es) -> {path}")
    print(f"  KILL (auto-reject in review) : {len(kills)}")
    print(f"  WARN (needs a written reason): {len(warns)}")
    for r in kills:
        print(f"\n  KILL {r['target'].split(':')[-1]}  {r['pattern']}")
        for why in r["kill_reasons"]:
            print(f"       {why}")
        for ex in (r.get("examples", {}).get("known_wrong_hit", [])
                   + r.get("examples", {}).get("rejected_hit", []))[:4]:
            print(f"         e.g. {ex['product']}")
    for r in warns[:12]:
        print(f"\n  WARN {r['target'].split(':')[-1]}  {r['pattern']}")
        for why in r["warn_reasons"]:
            print(f"       {why}")
        for ex in r.get("examples", {}).get("cross_commodity", [])[:3]:
            print(f"         e.g. {ex['product']}  (priced by {', '.join(ex.get('priced_by', []))})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
