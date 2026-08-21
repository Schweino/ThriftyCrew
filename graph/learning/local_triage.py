"""Local triage — move the MECHANICAL half of review work onto the free model.

    python graph/learning/local_triage.py --cluster-rejections [--limit N] [--jobs 4]
    python graph/learning/local_triage.py --draft-evidence \
           --commodity commodity:staple:tortilla-chips --product "Clancy's Spicy Margarita Chips"
    python graph/learning/local_triage.py --triage-queue [--top N]

Three jobs that were being done by hand, by Claude, at Claude prices:

1. CLUSTERING REJECTIONS. question_verdicts holds 3,755 adjudicated negatives
   (3,692 llm_rejected + 63 known_wrong as of 2026-08-21). Every category-exclude
   class this estate ships — beverage, snack_carrier, dried_carrier,
   prepared_meal_carrier, ... twelve of them — was spotted by a human noticing
   the same shape of mistake twice. That is pattern-matching over a labelled
   corpus, which is exactly what a free local model can do while the GPU would
   otherwise be idle. The output is a PROPOSAL report, never a rule: a family
   with 40 members and a clean example list is the evidence a human needs to
   decide whether a new class guard is warranted.

2. DRAFTING EVIDENCE PROSE. Every CONFIRM/REJECT in review_escalations must
   carry a one-sentence `evidence` naming the deciding words. Writing that
   sentence is transcription, not judgement. The model drafts it; the reviewer
   still rules. Nothing here writes a verdict, and --draft-evidence deliberately
   has no way to emit one.

3. TRIAGE ORDERING. Pure code, no model: the escalation queue arrives in the
   order the resolver happened to produce it, which has nothing to do with what
   a ruling buys. A question that settles 14 rows on a commodity with zero
   priced cells opens a board cell; one that settles 1 row on a commodity
   already priced at 6 stores changes almost nothing.

CONSTRAINTS THIS FILE HONOURS
  * READ-ONLY on graph.db (mode=ro URI). The daily pipeline is the single
    writer; a triage report must never contend with it.
  * Every model call is grammar-constrained AND bounded. A grammar constrains
    SHAPE, not LENGTH — see the note above CLUSTER_SCHEMA for the failure that
    lesson comes from.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import time
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
sys.path.insert(0, os.path.join(HERE, "..", "pipeline"))

from llm import LocalLLM                                    # noqa: E402

DB_PATH = os.path.join(REPO_ROOT, "graph", "sqlite", "graph.db")
QUEUE = os.path.join(REPO_ROOT, "grocery", "escalation-queue.json")
REPORT_DIR = os.path.join(REPO_ROOT, "grocery")


def open_ro() -> sqlite3.Connection:
    """Read-only handle. The URI form is not decoration: another session writes
    this file continuously, and a plain connect() would take a lock it is
    entitled to be refused."""
    conn = sqlite3.connect(f"file:{DB_PATH.replace(os.sep, '/')}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


# ---------------------------------------------------------------------------
# 1. cluster rejections into defect families
# ---------------------------------------------------------------------------

# Families already found BY HAND and shipped as category-exclude classes or as
# per-commodity rules. Seeded into the prompt so the model reuses a name that
# already exists instead of minting a synonym for it — and so anything it
# invents OUTSIDE this list is, by construction, the interesting part of the
# report.
KNOWN_FAMILIES = [
    "dried-herb-for-fresh",
    "prepared-meal-for-ingredient",
    "variety-pack-for-single-food",
    "concentrate-for-ready-to-serve",
    "dry-for-canned",
    "beverage-for-fruit",
    "snack-carrier-for-ingredient",
    "candy-for-fruit",
    "supplement-for-food",
    "pet-food-for-human-food",
    "household-nonfood",
    "baby-food-for-ingredient",
    "wrong-cut-or-grade",
    "wrong-variety",
    "flavoring-for-the-food",
]

# Batch size. 18 rejections per call measured 4.5s/call at --jobs 4 and left the
# prompt around 900 tokens — the whole 3,755-row corpus labelled in 209 calls and
# 949s of otherwise-idle GPU, with zero parse failures and zero dropped lines.
#
# BOUND EVERY ARRAY AND EVERY STRING. llama.cpp's grammar guarantees "legal so
# far", not "complete": stage1_analyze died on 2026-08-20 with a document that
# was a valid PREFIX because generation hit max_tokens mid-object. maxItems here
# is pinned to the batch size and the strings are short by design, so a full
# answer physically cannot outrun the 4096-token slot.
BATCH = 18

CLUSTER_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["labels"],
    "properties": {
        "labels": {
            "type": "array",
            "maxItems": BATCH,
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": ["n", "family"],
                "properties": {
                    "n": {"type": "integer", "minimum": 1, "maximum": BATCH},
                    "family": {"type": "string", "maxLength": 40},
                },
            },
        }
    },
}

CLUSTER_SYSTEM = (
    "You group ADJUDICATED MISTAKES from a grocery price board into named DEFECT "
    "FAMILIES.\n\n"
    "Each numbered line is a store product listing that was ruled NOT to be the "
    "commodity it was matched against. Your job is to name WHY it is wrong, in a "
    "way that would apply to many other listings — the shape of the error, not "
    "this one product.\n\n"
    "Answer with one short kebab-case family name per line, in the form "
    "<wrong-thing>-for-<right-thing> where that fits.\n"
    "Reuse a name from the KNOWN FAMILIES list whenever the mistake is that "
    "mistake. Invent a new name only when none of them describes it.\n"
    "Never use the product's brand or the commodity's name in the family — "
    "'clancys-chips' is useless, 'snack-carrier-for-ingredient' is useful.\n"
    # 'wrong-variety' swallowed 22 of 54 on the first real batch (2026-08-21).
    # A family that fits everything proposes nothing, and the whole point of
    # this mode is to surface the shape a class guard could be written against.
    "'wrong-variety' and 'wrong-cut-or-grade' are LAST RESORTS. Before using "
    "either, ask what KIND of difference it is — a different form (dried vs "
    "fresh, frozen vs refrigerated), a different processing state (cooked, "
    "seasoned, breaded, sweetened), a different container (canned vs dry), a "
    "flavoured version, an added-ingredient version — and name that instead.\n"
    "Output JSON only."
)


def _norm_family(name: str) -> str:
    """Collapse the model's spelling variance so counts mean something.

    Measured on real batches: the same defect comes back as 'Dried Herb For
    Fresh', 'dried_herb_for_fresh' and 'dried-herb-for-fresh'. Counting those as
    three families would hide the one thing this mode exists to surface.
    """
    s = (name or "").strip().lower().replace("_", "-").replace(" ", "-")
    s = "".join(c for c in s if c.isalnum() or c == "-")
    while "--" in s:
        s = s.replace("--", "-")
    return s.strip("-") or "unnamed"


def load_rejections(conn: sqlite3.Connection, limit: int | None) -> list[dict]:
    """The banked negatives, with the commodity LABEL rather than its id.

    The id (commodity:staple:parsley) is a slug the model has to parse; the
    node's canonical_name is the words a human wrote. Joining costs nothing and
    the prompt gets measurably more legible.
    """
    q = """SELECT v.commodity_id, COALESCE(n.canonical_name, v.commodity_id) AS label,
                  v.product_name, v.status
           FROM question_verdicts v
           LEFT JOIN nodes n ON n.id = v.commodity_id
           WHERE v.status IN ('llm_rejected','known_wrong')
             AND v.product_name IS NOT NULL AND v.product_name <> ''
           ORDER BY v.commodity_id, v.product_name"""
    rows = [dict(r) for r in conn.execute(q).fetchall()]
    if limit and limit < len(rows):
        # STRIDE, never LIMIT. The corpus is ordered by commodity id, so a SQL
        # LIMIT 400 would label an alphabetical prefix — every rejection on
        # almond-milk through canned-corn and nothing past it — and report the
        # defect families of the letter A. A stride spans the whole corpus while
        # keeping same-commodity rejections adjacent, which is what lets one
        # batch show the model the same mistake twice.
        step = len(rows) / float(limit)
        rows = [rows[int(i * step)] for i in range(limit)]
    return rows


def cluster_rejections(limit: int | None, jobs: int, out_path: str) -> dict:
    conn = open_ro()
    rows = load_rejections(conn, limit)
    if not rows:
        raise SystemExit("no banked rejections found")

    llm = LocalLLM()
    if not llm.health():
        raise SystemExit("local endpoint down — pwsh tools/local-llm/serve.ps1")

    batches = [rows[i:i + BATCH] for i in range(0, len(rows), BATCH)]
    known = "\n".join(f"  - {f}" for f in KNOWN_FAMILIES)

    def run(batch: list[dict]) -> list[tuple[dict, str]]:
        lines = "\n".join(
            f"{i}. commodity {r['label']!r} <- listing {r['product_name'][:90]!r}"
            for i, r in enumerate(batch, 1))
        user = (f"KNOWN FAMILIES (prefer these):\n{known}\n\n"
                f"REJECTED MATCHES:\n{lines}\n\n"
                f"Name the defect family for each of the {len(batch)} lines.")
        try:
            parsed, _ = llm.json_call(CLUSTER_SYSTEM, user, schema=CLUSTER_SCHEMA,
                                      max_tokens=700)
        except Exception as e:                                  # noqa: BLE001
            return [(r, f"__error__:{type(e).__name__}") for r in batch]
        by_n = {int(l.get("n", 0)): l.get("family", "") for l in parsed.get("labels", [])}
        # A dropped line is recorded as unlabelled rather than silently skipped:
        # a family count is only trustworthy if the denominator is honest.
        return [(r, _norm_family(by_n.get(i, "")) if by_n.get(i) else "__unlabelled__")
                for i, r in enumerate(batch, 1)]

    t0 = time.time()
    labelled: list[tuple[dict, str]] = []
    with ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        for i, part in enumerate(pool.map(run, batches), 1):
            labelled.extend(part)
            print(f"  batch {i}/{len(batches)} ({len(labelled)} rejections labelled)")

    fams: dict[str, list[dict]] = defaultdict(list)
    for r, fam in labelled:
        fams[fam].append(r)

    families = []
    for fam, members in sorted(fams.items(), key=lambda kv: -len(kv[1])):
        commodities = Counter(m["label"] for m in members)
        families.append({
            "family": fam,
            "already_known": fam in KNOWN_FAMILIES,
            "members": len(members),
            "distinct_commodities": len(commodities),
            "top_commodities": [c for c, _ in commodities.most_common(5)],
            "examples": [{"commodity": m["label"], "product": m["product_name"]}
                         for m in members[:4]],
        })

    report = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "source": "question_verdicts status IN (llm_rejected, known_wrong)",
        "rejections_labelled": len(labelled),
        "batches": len(batches),
        "elapsed_s": round(time.time() - t0, 1),
        "known_families_seeded": KNOWN_FAMILIES,
        "new_families": [f["family"] for f in families
                         if not f["already_known"] and not f["family"].startswith("__")],
        "families": families,
    }
    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(report, fh, indent=2, ensure_ascii=False)
    return report


# ---------------------------------------------------------------------------
# 2. draft the evidence sentence for a question the reviewer is about to rule on
# ---------------------------------------------------------------------------

EVIDENCE_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["deciding_words", "evidence"],
    "properties": {
        "deciding_words": {
            "type": "array", "maxItems": 5,
            "items": {"type": "string", "maxLength": 40},
        },
        "evidence": {"type": "string", "maxLength": 300},
    },
}


def _rubric() -> list[str]:
    """The reviewer's rubric, imported from review_escalations rather than
    retyped. Two copies of a rubric drift, and a drifted rubric means the
    drafted prose argues under a standard the ingest does not enforce."""
    from review_escalations import RUBRIC
    return list(RUBRIC)


def commodity_context(conn: sqlite3.Connection, cid: str) -> dict:
    node = conn.execute(
        "SELECT canonical_name, properties_json FROM nodes WHERE id=?", (cid,)).fetchone()
    if not node:
        raise SystemExit(f"no such commodity node: {cid}")
    props = json.loads(node["properties_json"] or "{}")
    cat = conn.execute(
        """SELECT n.canonical_name FROM nodes n JOIN edges e ON e.target_id=n.id
           WHERE e.predicate='in_category' AND e.source_id=? LIMIT 1""", (cid,)).fetchone()
    aliases = conn.execute(
        """SELECT a.alias, a.kind FROM aliases a WHERE a.node_id=?""", (cid,)).fetchall()
    siblings = [r[0] for r in conn.execute(
        """SELECT DISTINCT product_name FROM price_observations
           WHERE commodity_id=? AND match_status IN ('include_hit','llm_confirmed')
             AND product_name IS NOT NULL LIMIT 5""", (cid,)).fetchall()]
    rejected = [r[0] for r in conn.execute(
        """SELECT product_name FROM question_verdicts
           WHERE commodity_id=? AND status IN ('llm_rejected','known_wrong') LIMIT 6""",
        (cid,)).fetchall()]
    return {
        "commodity": cid,
        "label": node["canonical_name"],
        "unit_basis": props.get("unit_basis"),
        "category": cat[0] if cat else None,
        "include_patterns": [a["alias"] for a in aliases if a["kind"] == "include"][:8],
        "exclude_patterns": [a["alias"] for a in aliases if a["kind"] == "exclude"][:8],
        "confirmed_siblings": siblings,
        "already_rejected": rejected,
    }


def draft_evidence(cid: str, product: str, leaning: str | None) -> dict:
    conn = open_ro()
    ctx = commodity_context(conn, cid)
    llm = LocalLLM()
    if not llm.health():
        raise SystemExit("local endpoint down — pwsh tools/local-llm/serve.ps1")

    system = (
        "You DRAFT the one-sentence written evidence for a grocery price-board "
        "review. You do NOT decide the verdict — a human reviewer does that, and "
        "your sentence is a draft they will edit or discard.\n\n"
        "The sentence must NAME THE SPECIFIC WORDS in the product listing that "
        "decide the question. 'It is not the same product' is worthless; 'the "
        "listing says DRIED, and the commodity is fresh parsley sold by the "
        "bunch' is the standard.\n\n"
        "REVIEW RUBRIC this evidence is written under:\n"
        + "\n".join(f"  - {r}" for r in _rubric())
        + "\nOne sentence. No verdict word. Output JSON only."
    )
    ask = ("Draft the evidence sentence supporting a {} ruling."
           .format(leaning.upper()) if leaning else
           "Draft a neutral evidence sentence naming the words that decide it, "
           "without asserting which way it goes.")
    user = "\n".join([
        f"COMMODITY: {ctx['label']} ({ctx['commodity']})",
        f"category: {ctx['category']}   sold by: {ctx['unit_basis'] or 'unspecified'}",
        f"include patterns: {ctx['include_patterns']}",
        f"exclude patterns: {ctx['exclude_patterns']}",
        f"already CONFIRMED for this commodity: {ctx['confirmed_siblings']}",
        f"already REJECTED for this commodity: {ctx['already_rejected']}",
        f"\nSTORE PRODUCT LISTING: {product!r}\n",
        ask,
    ])
    parsed, res = llm.json_call(system, user, schema=EVIDENCE_SCHEMA, max_tokens=320)
    return {
        "commodity": ctx["commodity"],
        "label": ctx["label"],
        "product": product,
        "drafted_for": leaning.upper() if leaning else None,
        "deciding_words": [str(w)[:40] for w in (parsed.get("deciding_words") or [])][:5],
        "evidence_draft": str(parsed.get("evidence", ""))[:300],
        # The reviewer's decision is deliberately absent from the model's output
        # and present as a hole in this record. Nothing downstream can mistake a
        # draft for a ruling.
        "verdict": "REVIEWER DECIDES — this tool never rules",
        "model": res.model,
        "completion_tokens": res.completion_tokens,
    }


# ---------------------------------------------------------------------------
# 3. re-order the escalation queue by what a ruling would UNLOCK  (no model)
# ---------------------------------------------------------------------------

def _queue() -> list[dict]:
    if not os.path.exists(QUEUE):
        return []
    try:
        with open(QUEUE, encoding="utf-8-sig") as fh:
            data = json.load(fh)
    except (json.JSONDecodeError, OSError):
        return []
    return data if isinstance(data, list) else []


def triage_queue(top: int | None, out_path: str) -> dict:
    conn = open_ro()
    entries = _queue()
    if not entries:
        raise SystemExit(f"escalation queue empty or missing: {QUEUE}")

    # One pass for every commodity in the queue: how many stores already price
    # it. A commodity at 0 priced stores has an EMPTY board cell, which is the
    # thing a ruling can actually open; one already priced at six stores gains
    # at most a better number.
    priced = {r["commodity_id"]: r["n"] for r in conn.execute(
        "SELECT commodity_id, COUNT(DISTINCT store_id) AS n FROM v_current_cell "
        "GROUP BY commodity_id").fetchall()}

    # The status each kind's rows are WAITING in (review_escalations.KIND_STATUS).
    waiting_on = {"confirm_match": "llm_match_unverified", "contested": "escalated"}

    scored = []
    for e in entries:
        cid = e.get("commodity", "")
        product = e.get("product") or ""
        want = waiting_on.get(e.get("kind"), "escalated")
        rows = [dict(r) for r in conn.execute(
            """SELECT store_id, match_status FROM price_observations
               WHERE commodity_id=? AND product_name=?""", (cid, product)).fetchall()]
        live = [r for r in rows if r["match_status"] == want]
        stores = sorted({r["store_id"].replace("store:", "") for r in live})
        # rows_settled is read LIVE, never from the queue entry. Measured on the
        # 2026-08-21 queue: entries claimed 19-22 rows settled while the database
        # held ONE row for the question — the resolver's dedupe count was banked
        # when the queue was written and the corpus has been re-adjudicated
        # since. Sorting by a stale leverage number sorts by history.
        settled = len(live)
        stale_as = Counter(r["match_status"] for r in rows if r["match_status"] != want)
        priced_stores = priced.get(cid, 0)

        # UNLOCK SCORE. Additive and readable on purpose — a reviewer must be
        # able to see why a question is at the top, and a tuned black box that
        # nobody can argue with is worse than a crude rule that they can.
        #   * opening the FIRST priced store for a commodity is the jackpot: an
        #     empty board cell becomes a real one.
        #   * a second/third store makes the cell comparable (the board's whole
        #     purpose is cross-store comparison), so it still scores well.
        #   * rows_settled is the leverage of one answer over the corpus.
        #   * a confirm_match lead is cheaper to review than a contested
        #     question ruled from scratch — same payoff, less reviewer time.
        # STALE FIRST. A queue entry whose rows have left the status it is
        # waiting in is already settled — the deterministic layers reached it
        # after the resolver queued it, or a reviewer ruled it in another
        # session. 42 of the 50 entries on the 2026-08-21 queue are in exactly
        # this state (18 now include_hit, 22 back to no_include_hit awaiting
        # re-adjudication, 1 known_wrong). Reviewing one of these buys nothing,
        # so they sink to the bottom with the reason stated.
        if not live:
            scored.append({
                "unlock_score": -100,
                "why": "STALE — no rows left in '%s'; now %s" % (
                    want, dict(stale_as) or "gone"),
                "commodity": cid, "product": product, "kind": e.get("kind"),
                "rows_settled": 0, "stores_affected": [],
                "commodity_priced_stores": priced_stores,
                "confidence": e.get("confidence"),
                "observation": e.get("observation"),
                "previously_deferred": bool(e.get("deferred_reason")),
                "stale": True,
            })
            continue

        if priced_stores == 0:
            unlock = 100
            why = "opens the first priced store for this commodity"
        elif priced_stores < 3:
            unlock = 40
            why = f"makes the cell comparable ({priced_stores} store(s) priced today)"
        else:
            unlock = 10
            why = f"commodity already priced at {priced_stores} stores"
        score = unlock + 3 * settled + 5 * len(stores)
        if e.get("kind") == "confirm_match":
            score += 8
            why += "; model already drafted a MATCH lead (cheap confirm)"
        if e.get("deferred_reason"):
            # A previously deferred question needs evidence a title cannot
            # supply. Ranking it first burns the session on a store-page hunt.
            score -= 25
            why += "; previously DEFERRED (needs store-page evidence)"

        scored.append({
            "unlock_score": score,
            "why": why,
            "commodity": cid,
            "product": product,
            "kind": e.get("kind"),
            "rows_settled": settled,
            "stores_affected": stores,
            "commodity_priced_stores": priced_stores,
            "confidence": e.get("confidence"),
            "observation": e.get("observation"),
            "previously_deferred": bool(e.get("deferred_reason")),
            "stale": False,
        })

    scored.sort(key=lambda x: (-x["unlock_score"], x["commodity"]))
    report = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "source_queue": QUEUE,
        "entries": len(scored),
        "unpriced_commodities": sum(1 for s in scored if s["commodity_priced_stores"] == 0),
        "stale_entries": sum(1 for s in scored if s["stale"]),
        "live_rows_total": sum(s["rows_settled"] for s in scored),
        "ordered": scored[:top] if top else scored,
    }
    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(report, fh, indent=2, ensure_ascii=False)
    return report


# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--cluster-rejections", action="store_true")
    ap.add_argument("--draft-evidence", action="store_true")
    ap.add_argument("--triage-queue", action="store_true")
    ap.add_argument("--limit", type=int, default=None,
                    help="cluster: how many banked rejections to label")
    ap.add_argument("--jobs", type=int, default=4,
                    help="concurrent model calls; must be <= llama-server --parallel slots")
    ap.add_argument("--commodity", default=None)
    ap.add_argument("--product", default=None)
    ap.add_argument("--leaning", choices=["confirm", "reject"], default=None,
                    help="draft the sentence supporting this ruling; the reviewer still decides")
    ap.add_argument("--top", type=int, default=None)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    if args.cluster_rejections:
        out = args.out or os.path.join(REPORT_DIR, "defect-families.json")
        rep = cluster_rejections(args.limit, args.jobs, out)
        print(f"\nlabelled {rep['rejections_labelled']} rejections in "
              f"{rep['batches']} batches, {rep['elapsed_s']}s -> {out}")
        for f in rep["families"]:
            tag = "known" if f["already_known"] else "NEW  "
            print(f"  [{tag}] {f['family']:<38} {f['members']:>4} members, "
                  f"{f['distinct_commodities']} commodities")
        return 0

    if args.draft_evidence:
        if not (args.commodity and args.product):
            ap.error("--draft-evidence needs --commodity and --product")
        rep = draft_evidence(args.commodity, args.product, args.leaning)
        print(json.dumps(rep, indent=2, ensure_ascii=False))
        return 0

    if args.triage_queue:
        out = args.out or os.path.join(REPORT_DIR, "escalation-triage.json")
        rep = triage_queue(args.top, out)
        print(f"{rep['entries']} queued questions, "
              f"{rep['unpriced_commodities']} on commodities with NO priced cell, "
              f"{rep['stale_entries']} already settled (stale), "
              f"{rep['live_rows_total']} live rows at stake -> {out}\n")
        for s in rep["ordered"]:
            print(f"  {s['unlock_score']:>4}  {s['kind']:<13} {s['commodity']}")
            print(f"        {s['product'][:70]!r}")
            print(f"        {s['rows_settled']} rows, stores={','.join(s['stores_affected']) or '-'}"
                  f" | {s['why']}")
        return 0

    ap.error("pick one of --cluster-rejections / --draft-evidence / --triage-queue")


if __name__ == "__main__":
    raise SystemExit(main())
