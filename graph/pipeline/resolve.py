"""Resolve — decide whether a candidate product row IS a given commodity.

This is the highest-risk stage in the whole system (plan §3.1), so it is built in
LAYERS, cheapest and most certain first. A model is only ever consulted for rows
the deterministic layers cannot settle.

    1. KNOWN-WRONG      an adjudicated negative with written evidence. Absolute.
    2. CATEGORY-EXCLUDE wrong-CLASS guardrails (the blueberries-as-Bai-beverage
                        class of defect). Absolute.
    3. EXCLUDE regex    the commodity's own negative patterns. Absolute.
    4. INCLUDE regex    the commodity's positive patterns. A hit is a match.
    5. LLM adjudication ONLY for rows that reach here — no include hit but no
                        exclusion either. This is the genuinely contested set.

Layers 1-4 are the "blocking" the plan mandates before expensive LLM resolution.
On real data they settle the overwhelming majority of rows, which is what keeps
Claude/local volume low and the false-merge rate down.

BIAS: prefer a MISSED merge over a FALSE merge. A missed merge costs one empty
board cell; a false merge publishes a wrong price, which is the failure mode this
whole estate is built to prevent (see the 2026-07-14 blueberries incident and the
2026-07-28 coconut-oil/Epsom-salt crown in known-wrong.json).
"""

from __future__ import annotations

import os
import re
import sys
import time
from dataclasses import dataclass

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))

from graphdb import GraphDB                        # noqa: E402
from ids import norm_text                          # noqa: E402
from llm import LocalLLM, should_escalate          # noqa: E402

PROMPTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "prompts")

# Grammar schema for the adjudication call — guarantees parseable output.
RESOLVE_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["verdict", "confidence", "evidence"],
    "properties": {
        "verdict": {"type": "string", "enum": ["MATCH", "NO_MATCH", "UNSURE"]},
        "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        "evidence": {"type": "string",
                     "description": "the specific words in the product name that decide it"},
    },
}


@dataclass
class Verdict:
    status: str          # matches price_observations.match_status
    reason: str
    confidence: float = 1.0
    escalate: bool = False

    @property
    def is_match(self) -> bool:
        return self.status in ("include_hit", "llm_confirmed")


class CompiledCommodity:
    """A commodity's resolution rules, compiled once and reused across thousands
    of candidate rows. Compiling per-row was measurably the slow path."""

    __slots__ = ("node_id", "label", "unit", "include", "exclude", "known_wrong",
                 "raw_include", "category", "active_classes")

    def __init__(self, node_id: str, label: str, unit: str | None,
                 include: list[str], exclude: list[str], known_wrong: set[str],
                 category: str | None = None, active_classes: frozenset[str] = frozenset()):
        self.node_id = node_id
        self.label = label
        self.unit = unit
        self.raw_include = include
        self.include = _compile_all(include)
        self.exclude = _compile_all(exclude)
        self.known_wrong = known_wrong
        self.category = category
        # Which wrong-class guardrails are in force for THIS commodity's category.
        self.active_classes = active_classes


def _compile_all(patterns: list[str]) -> list[re.Pattern]:
    out = []
    for p in patterns:
        try:
            out.append(re.compile(p, re.IGNORECASE))
        except re.error:
            # A malformed stored regex must not take down a pipeline run. It is
            # skipped and surfaced by audit rather than raised here.
            continue
    return out


class Resolver:
    def __init__(self, db: GraphDB, llm: LocalLLM | None = None,
                 use_llm: bool = True, escalate_below: float = 0.75):
        self.db = db
        self.llm = llm
        self.use_llm = use_llm
        self.escalate_below = escalate_below
        self._cache: dict[str, CompiledCommodity] = {}
        self._catex: list[tuple[re.Pattern, str, re.Pattern | None]] = []
        self._class_scope: dict[str, set[str]] = {}
        self._universal_classes: set[str] = set()
        self._load_category_excludes()
        self.stats: dict[str, int] = {}

    # -- setup -------------------------------------------------------------
    def _load_category_excludes(self) -> None:
        """Load the wrong-class guardrails AND the scoping that governs them.

        CRITICAL: these classes are SCOPED by category, not global. The `apply`
        rules in category-excludes.json say e.g. "the household class applies to
        commodities in ^(Fruit|Vegetables)$" — so a *household* commodity like
        bar-soap must NOT be rejected for matching 'bar soap'. Applying every
        class to every commodity blanket-rejects whole categories; the gold set
        caught exactly that (bar-soap, body-wash, bagels, cereal, baby-food all
        went missing before this scoping was honoured).
        """
        import json
        rows = self.db.conn.execute(
            "SELECT canonical_name, properties_json FROM nodes WHERE type='CategoryExclude'"
        ).fetchall()
        for r in rows:
            props = json.loads(r["properties_json"] or "{}")
            pat, exempt = props.get("pattern"), props.get("exempt")
            if not pat:
                continue
            try:
                cpat = re.compile(pat, re.IGNORECASE)
            except re.error:
                continue
            cex = None
            if exempt:
                try:
                    cex = re.compile(exempt, re.IGNORECASE)
                except re.error:
                    cex = None
            cls = props.get("class", "?")
            self._catex.append((cpat, cls, cex))
            # class -> the category-label regexes it is enforced against
            for cat_pat in props.get("applies_to_categories") or []:
                if cat_pat:
                    self._class_scope.setdefault(cls, set()).add(cat_pat)
            if props.get("universal_for_unknown"):
                self._universal_classes.add(cls)

    def _active_classes_for(self, category_label: str | None) -> frozenset[str]:
        """Which guardrail classes are in force for a commodity in this category."""
        if not category_label:
            # No category known: only the universal-for-unknown classes apply.
            return frozenset(self._universal_classes)
        active = set()
        for cls, patterns in self._class_scope.items():
            for p in patterns:
                try:
                    if re.search(p, category_label, re.IGNORECASE):
                        active.add(cls)
                        break
                except re.error:
                    continue
        return frozenset(active)

    def commodity(self, node_id: str) -> CompiledCommodity:
        if node_id in self._cache:
            return self._cache[node_id]
        node = self.db.get_node(node_id)
        if not node:
            raise KeyError(f"no such commodity node: {node_id}")
        inc = [a["alias"] for a in self.db.aliases_for(node_id, "include")]
        exc = [a["alias"] for a in self.db.aliases_for(node_id, "exclude")]
        kw = {
            norm_text(r["canonical_name"])
            for r in self.db.conn.execute(
                """SELECT n.canonical_name FROM nodes n
                   JOIN edges e ON e.source_id = n.id
                   WHERE e.predicate='known_wrong_for' AND e.target_id=?""",
                (node_id,)).fetchall()
        }
        cat = self.db.conn.execute(
            """SELECT n.canonical_name FROM nodes n
               JOIN edges e ON e.target_id = n.id
               WHERE e.predicate='in_category' AND e.source_id=? LIMIT 1""",
            (node_id,)).fetchone()
        category = cat["canonical_name"] if cat else None

        import json
        props = json.loads(node["properties_json"] or "{}")
        cc = CompiledCommodity(node_id, node["canonical_name"], props.get("unit_basis"),
                               inc, exc, kw, category,
                               self._active_classes_for(category))
        self._cache[node_id] = cc
        return cc

    # -- the layered decision ---------------------------------------------
    def resolve(self, commodity_node_id: str, product_name: str,
                allow_llm: bool = True) -> Verdict:
        cc = self.commodity(commodity_node_id)
        name = product_name or ""
        norm = norm_text(name)

        # 1. known-wrong: an adjudicated negative. Absolute, never re-litigated.
        if norm in cc.known_wrong:
            return self._tally(Verdict("known_wrong",
                                       "adjudicated known-wrong for this commodity", 1.0))

        # 2. wrong-class guardrails — ONLY the classes in force for this
        #    commodity's category (see _load_category_excludes).
        for pat, cls, exempt in self._catex:
            if cls not in cc.active_classes:
                continue
            if pat.search(name) and not (exempt and exempt.search(name)):
                return self._tally(Verdict("category_excluded",
                                           f"matched wrong-class token '{pat.pattern}' ({cls})", 1.0))

        # 3. the commodity's own negatives.
        for pat in cc.exclude:
            if pat.search(name):
                return self._tally(Verdict("excluded",
                                           f"matched exclude pattern '{pat.pattern}'", 1.0))

        # 4. the commodity's own positives.
        for pat in cc.include:
            if pat.search(name):
                return self._tally(Verdict("include_hit",
                                           f"matched include pattern '{pat.pattern}'", 1.0))

        # 5. genuinely contested: no positive hit, but nothing rules it out.
        if not (allow_llm and self.use_llm and self.llm):
            return self._tally(Verdict("no_include_hit", "no include pattern matched", 1.0))
        return self._tally(self._llm_adjudicate(cc, name))

    def _llm_adjudicate(self, cc: CompiledCommodity, name: str) -> Verdict:
        system, user = build_resolve_prompt(cc, name)
        try:
            parsed, res = self.llm.json_call(system, user, schema=RESOLVE_SCHEMA, max_tokens=400)
        except Exception as e:                                  # noqa: BLE001
            return Verdict("escalated", f"llm error: {e}", 0.0, escalate=True)

        verdict = str(parsed.get("verdict", "UNSURE")).upper()
        conf = float(parsed.get("confidence", 0.0) or 0.0)
        why = str(parsed.get("evidence", ""))[:400]

        if verdict == "MATCH" and not should_escalate(conf, self.escalate_below):
            return Verdict("llm_confirmed", f"llm: {why}", conf)
        if verdict == "NO_MATCH" and not should_escalate(conf, self.escalate_below):
            return Verdict("llm_rejected", f"llm: {why}", conf)
        # UNSURE, or a confident-sounding answer below threshold -> escalate.
        # Preferring a missed merge over a false one, an escalation does NOT
        # price a cell while it waits for Claude.
        return Verdict("escalated", f"llm {verdict} conf={conf:.2f}: {why}", conf, escalate=True)

    def _tally(self, v: Verdict) -> Verdict:
        self.stats[v.status] = self.stats.get(v.status, 0) + 1
        return v

    # -- bulk application --------------------------------------------------
    def resolve_pending(self, limit: int | None = None, run: str = "",
                        ts: str | None = None, allow_llm: bool = True,
                        progress=None) -> dict:
        """Adjudicate every unadjudicated observation, writing status back.

        Deterministic layers run for ALL rows. The LLM layer is applied only to
        the contested remainder, and only when allow_llm is set — which is how a
        Phase 2 shadow run can score the deterministic layer in isolation.
        """
        ts = ts or time.strftime("%Y-%m-%dT%H:%M:%S")
        q = """SELECT id, commodity_id, product_name FROM price_observations
               WHERE match_status='unadjudicated'"""
        if limit:
            q += f" LIMIT {int(limit)}"
        rows = self.db.conn.execute(q).fetchall()

        n = 0
        escalations = []
        for r in rows:
            try:
                v = self.resolve(r["commodity_id"], r["product_name"] or "", allow_llm=allow_llm)
            except KeyError:
                v = Verdict("escalated", "commodity node missing", 0.0, escalate=True)
            self.db.conn.execute(
                "UPDATE price_observations SET match_status=?, match_reason=?, confidence=? WHERE id=?",
                (v.status, v.reason, v.confidence, r["id"]))
            if v.escalate:
                escalations.append({"observation": r["id"], "commodity": r["commodity_id"],
                                    "product": r["product_name"], "reason": v.reason})
            n += 1
            if progress and n % 2000 == 0:
                progress(f"    resolved {n}/{len(rows)}")
        self.db.conn.commit()

        if run:
            self.db.log_event(run=run, timestamp=ts, etype="resolve",
                              decision="resolve_pending",
                              detail={"n": n, "by_status": self.stats,
                                      "escalations": len(escalations)})
        return {"resolved": n, "by_status": dict(self.stats), "escalations": escalations}


def build_resolve_prompt(cc: CompiledCommodity, product_name: str) -> tuple[str, str]:
    """Build the adjudication prompt.

    The system prompt carries this catalog's SEMANTICS, not just generic
    instructions. Phase 0 validation found that a naked prompt confidently
    rejected "Jennie-O Lean Ground Turkey 93/7, 16 oz" as ground-turkey on the
    reasoning that a packaged retail item is not a raw commodity — plausible in
    the abstract, wrong for this board, which prices exactly such packaged items.
    Stating the domain rules is what fixes that class of error.
    """
    system = (
        "You adjudicate whether a grocery store's product listing IS a given "
        "commodity on an Omaha price-comparison board.\n\n"
        "DOMAIN RULES (this board's semantics, not general knowledge):\n"
        "- The board prices PACKAGED RETAIL PRODUCTS. A branded, packaged item is "
        "a valid instance of a commodity. 'Jennie-O Ground Turkey 16oz' IS ground turkey.\n"
        "- Store brands and national brands both count. Brand is never a reason to reject.\n"
        "- Package SIZE is never a reason to reject; the board normalises per unit.\n"
        "- REJECT when the product is a different FOOD, a different CUT or GRADE than "
        "the commodity names, a prepared/cooked form when the commodity is raw, or a "
        "non-food item that merely mentions the food.\n"
        "- A variety difference IS a rejection when the commodity names the variety "
        "(Deglet Noor dates are NOT Medjool dates; 93/7 turkey is not 85/15).\n\n"
        "BIAS: prefer a missed match over a false one. If the listing is ambiguous, "
        "answer UNSURE rather than guessing — a wrong MATCH publishes a wrong price.\n"
        "Cite the specific words that decide it. Output JSON only."
    )
    inc = cc.raw_include[:8]
    user = (
        f"COMMODITY: {cc.label}\n"
        f"sold by: {cc.unit or 'unspecified'}\n"
        f"known surface patterns: {inc}\n\n"
        f"STORE PRODUCT LISTING: {product_name!r}\n\n"
        "Is this listing that commodity?"
    )
    return system, user


def main() -> int:
    """CLI: adjudicate every unadjudicated observation.

        python graph/pipeline/resolve.py              # deterministic layers only
        python graph/pipeline/resolve.py --llm        # + LLM on the contested set
        python graph/pipeline/resolve.py --llm --limit 500
    """
    import argparse
    import json as _json
    from graphdb import open_db

    ap = argparse.ArgumentParser(description="Resolve candidate rows to commodities")
    ap.add_argument("--llm", action="store_true",
                    help="consult the local model on rows the deterministic layers cannot settle")
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--reset", action="store_true",
                    help="re-adjudicate everything (clears prior verdicts first)")
    args = ap.parse_args()

    llm = None
    if args.llm:
        llm = LocalLLM()
        if not llm.health():
            print("local endpoint down — start it: pwsh tools/local-llm/serve.ps1",
                  file=sys.stderr)
            return 2

    run = f"run:resolve:{time.strftime('%Y%m%dT%H%M%S')}"
    with open_db() as db:
        if args.reset:
            db.conn.execute("UPDATE price_observations SET match_status='unadjudicated', "
                            "match_reason=NULL")
            db.conn.commit()
        r = Resolver(db, llm=llm, use_llm=bool(llm))
        t0 = time.time()
        out = r.resolve_pending(limit=args.limit, run=run, allow_llm=bool(llm),
                                progress=print)
        print(f"\nresolved {out['resolved']} rows in {time.time()-t0:.1f}s")
        for k, v in sorted(out["by_status"].items(), key=lambda x: -x[1]):
            print(f"   {k:<20} {v}")
        if out["escalations"]:
            print(f"\n   {len(out['escalations'])} rows escalated for Claude review")
            qp = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "..", "..", "grocery", "escalation-queue.json")
            with open(os.path.abspath(qp), "w", encoding="utf-8") as fh:
                _json.dump(out["escalations"], fh, indent=2, ensure_ascii=False)
            print(f"   wrote {os.path.abspath(qp)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
