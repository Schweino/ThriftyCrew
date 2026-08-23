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

THE LOCAL MODEL MAY ONLY REJECT, NEVER MINT A PRICE (decision 2026-08-20).
Layer 5's authority is asymmetric by design:

    NO_MATCH, confident  -> llm_rejected          (prunes the candidate)
    MATCH,    confident  -> llm_match_unverified  (CANNOT price; queued for the
                                                   Claude reviewer to confirm)
    UNSURE / low conf    -> escalated

Why: decomposing the Phase 0 bench (seed 20260820) showed the headline 0.900
agreement was 22/22 on gold MATCH cases but only 5/8 on gold NO_MATCH — and all
three errors were FALSE MATCHES at confidence 0.95-0.98, far above any sane
escalation threshold. Confidence does not discriminate this model's false
matches, so no threshold makes a local MATCH safe to publish. A confident local
MATCH is still valuable: it feeds the escalation queue (Claude confirms cheaply)
and the learning loop (a confirmed match becomes an include-alias proposal, and
the deterministic layers take over from there).

BIAS: prefer a MISSED merge over a FALSE merge. A missed merge costs one empty
board cell; a false merge publishes a wrong price, which is the failure mode this
whole estate is built to prevent (see the 2026-07-14 blueberries incident and the
2026-07-28 coconut-oil/Epsom-salt crown in known-wrong.json).

THE MODEL IS SHOWN THIS BOARD'S OWN PRIOR RULINGS (prompt v4, 2026-08-20).
Until v4 it judged blind — include patterns and nothing else — while the human
review packet for the SAME question carried the excludes, the confirmed
siblings and the known-wrong list. 2,551 adjudicated rejections sat unused.
Retrieving the handful most similar to the listing under judgement, measured
leave-one-out on 60 gold cases whose commodities carry history:

    false MATCH   14/26 (54%)  ->  7-8/26 (29%)
    correct       38           ->  48-49
    escalated      7           ->  3
    false reject   1/34        ->  1/34  (unchanged)

Roughly half the dangerous error and half the human review, for no new missed
merges, using labels the estate had already paid for. Leave-one-out matters:
many gold cases ARE banked rejections, so a case must never appear among its
own examples or the number measures memory instead of learning.

ONLY ADJUDICATED RULINGS COUNT AS PRECEDENT (prompt v5, 2026-08-22, plan §3.1).
v4 cited every banked ruling, and 3,315 of the 3,692 `llm_rejected` rows are the
local model's OWN unreviewed work — so it was shown its own guesses under the
heading ALREADY RULED, a wrong rejection became the authority for rejecting its
neighbours, and nothing in the loop ever reviewed it. v5 cites a ruling only when
a human, the Claude review lane or a known-wrong node made it; model-consensus
rulings (helper + LLM, phase 3) are shown in a separate list labelled tentative;
single-model rulings are shown nowhere. They still prune their own row — they
stop testifying about other rows. Who ruled what is decided in one place,
graph/lib/authority.py, because `question_verdicts.decided_by` cannot say: it was
derived from the status prefix, so reviewer rulings were stamped 'model' too.

Measured the same way, leave-one-out, 2 x 120 gold cases whose commodities carry
history (graph/bench/priors_ablation.py, seeds 20260822/20260823, 240 total):

                            v4 (all rulings)   v5 (adjudicated only)
    false MATCH             34/90 = 38%        33/90 = 37%
    correct                 191                188
    escalated                12                 16
    false reject             3/150              3/150   unchanged
    priors shown per case     5.9                3.3

Free on the metric that matters: the dangerous error did not move (the two runs
differ from each other by more), the missed-merge rate is identical, and the cost
is ~4 more escalations per 240 — cases the model declines instead of deciding on
its own past word, which is the direction this file's bias already prefers.

The honest cold-start baseline for all of this is 0.79 agreement, not the 0.900
in model-selection.md: that figure was measured with no priors while production
sends them. See graph/prompts/model-selection.md, addendum 2026-08-22.
"""

from __future__ import annotations

import os
import re
import sqlite3
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))

from graphdb import GraphDB                        # noqa: E402
from ids import hash_obj, norm_text                # noqa: E402
from authority import (authority_tier, CITABLE_AS_PRECEDENT,   # noqa: E402
                       CITABLE_AS_TENTATIVE)
from llm import LocalLLM, should_escalate          # noqa: E402

PROMPTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "prompts")

# Version of build_resolve_prompt + the layer-5 authority policy. Recorded on
# every per-judgment decision-log row so a verdict can be attributed to the
# exact prompt and policy that produced it. Bump on ANY change to either.
PROMPT_VERSION = "resolve-v5-reject-only-adjudicated-priors"

# Verdicts are banked to SQLite every this many questions during the LLM pass,
# so a long run is interruptible and resumable rather than all-or-nothing.
CHECKPOINT_EVERY = 200

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
    # None = nobody asserted a confidence. Deterministic layers that MATCHED
    # assert 1.0; "no pattern matched" is an absence of knowledge, not certainty.
    confidence: float | None = None
    escalate: bool = False
    # Set only by the LLM layer: everything the decision log needs to attribute
    # this judgment to a model + prompt version (model, hashes, verdict, tokens).
    meta: dict | None = None

    @property
    def is_match(self) -> bool:
        # llm_match_unverified is deliberately NOT here: a local-model MATCH is
        # a lead for the reviewer, not a match the board may act on.
        return self.status in ("include_hit", "llm_confirmed")


class CompiledCommodity:
    """A commodity's resolution rules, compiled once and reused across thousands
    of candidate rows. Compiling per-row was measurably the slow path."""

    __slots__ = ("node_id", "label", "unit", "include", "exclude", "known_wrong", "known_wrong_cores",
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
        # Same rulings, packaging noise stripped - see _kw_core.
        self.known_wrong_cores = {c for c in (_kw_core(k) for k in known_wrong) if c}
        self.category = category
        # Which wrong-class guardrails are in force for THIS commodity's category.
        self.active_classes = active_classes


# Noise a store adds around a product name without changing the product: a
# leading multipack prefix, a trailing size/count, and packaging words.
_KW_PREFIX = re.compile(r"^\s*\(?\s*\d+\s*(?:pack|pk|ct|count|x)\s*\)?\s*", re.I)
_KW_TRAIL = re.compile(
    r"[\s,\-]*\b\d+(?:\.\d+)?\s*"
    r"(?:oz|ounces?|fl\.?\s*oz|lb|lbs|pounds?|g|kg|ml|l|ct|count|pk|pack|ea|each)\b"
    r"[\s.\-]*$", re.I)


def _kw_core(norm_name: str) -> str:
    """The identity of a listing with packaging noise stripped.

    Deliberately conservative: it removes only a LEADING pack prefix and a
    TRAILING size, both of which a store adds to the same product. It does not
    touch interior words, so 'Diet Coke' can never collapse into 'Coke'.
    Returns '' when stripping leaves too little to be an identity, so a ruling
    can never widen into a near-empty token that matches everything.
    """
    s = _KW_PREFIX.sub("", norm_name or "")
    prev = None
    while prev != s:                     # a name can carry both "12 oz" and "4 ct"
        prev = s
        s = _KW_TRAIL.sub("", s)
    s = s.strip()
    return s if len(s) >= 8 and len(s.split()) >= 2 else ""


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
                 use_llm: bool = True, escalate_below: float = 0.75,
                 use_bank: bool = True):
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
        # Verdicts banked by question_verdicts. Only MODEL/REVIEWER answers are
        # reused (see layer 4.5) — the expensive ones. Absent table (a fresh
        # index mid-migration) simply means no bank, never an error.
        self.bank: dict[tuple[str, str], dict] = {}
        if use_bank:
            try:
                self.bank = {
                    (r["commodity_id"], r["product_key"]):
                        {"status": r["status"], "reason": r["reason"],
                         "confidence": r["confidence"]}
                    for r in self.db.conn.execute(
                        """SELECT commodity_id, product_key, status, reason, confidence
                           FROM question_verdicts
                           WHERE status IN ('llm_rejected','llm_confirmed',
                                            'llm_match_unverified','escalated')""")}
            except Exception:                                # noqa: BLE001
                self.bank = {}

        # Prior-ruling index for few-shot retrieval: commodity -> [(name, words,
        # kind, tier)]. Built once; the model is otherwise asked to judge blind
        # while the human review packet for the same question gets all of this.
        #
        # TIER is the 2026-08-22 fix (plan §3.1). Until now this index pulled
        # every llm_rejected row regardless of who decided it, and 3,315 of the
        # 3,692 are the local model's OWN unreviewed rejections — so the model
        # was shown its own guesses as "already ruled", a wrong rejection became
        # the authority for rejecting its neighbours, and nothing reviewed any of
        # it. graph/lib/authority.py decides who actually ruled; prior_rulings()
        # decides who is allowed to testify.
        self._verdict_index: dict[str, list[tuple[str, set[str], str, str]]] = {}
        self.prior_tier_counts: dict[str, int] = {}
        if use_bank:
            try:
                rows = self.db.conn.execute(
                    """SELECT commodity_id, product_name, status, reason, decided_by
                       FROM question_verdicts
                       WHERE status IN ('llm_rejected','known_wrong','llm_confirmed')
                       UNION ALL
                       SELECT n.id, k.canonical_name, 'known_wrong', 'adjudicated: known-wrong node', 'reviewer'
                       FROM nodes k JOIN edges e ON e.source_id=k.id
                            AND e.predicate='known_wrong_for'
                       JOIN nodes n ON n.id=e.target_id
                       WHERE k.type='KnownWrong'""").fetchall()
                for r in rows:
                    nm = r[1]
                    if not nm:
                        continue
                    kind = "confirm" if r[2] == "llm_confirmed" else "reject"
                    tier = authority_tier(r[2], r[3], r[4])
                    self.prior_tier_counts[tier] = self.prior_tier_counts.get(tier, 0) + 1
                    self._verdict_index.setdefault(r[0], []).append(
                        (nm, set(re.findall(r"[a-z]{3,}", nm.lower())), kind, tier))
            except Exception:                                # noqa: BLE001
                self._verdict_index = {}
                self.prior_tier_counts = {}

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
        #
        # Matched on the ruling's CORE, not on an exact string. Stores re-list
        # the same product with a pack prefix or a trailing size, and an
        # exact-name ruling misses every variant: the Master of Mixes daiquiri
        # mixer was ruled wrong under its long form in the morning and was back
        # pricing strawberries under its short form by the afternoon, and
        # 'Simply Asia Five Spice Stir-Fry Sauce' returned as '(4 pack) Simply
        # Asia Five Spice Stir-Fry Sauce'. A ruling that a store can escape by
        # re-listing is not a ruling.
        if norm in cc.known_wrong:
            return self._tally(Verdict("known_wrong",
                                       "adjudicated known-wrong for this commodity", 1.0))
        core = _kw_core(norm)
        if core and core in cc.known_wrong_cores:
            return self._tally(Verdict(
                "known_wrong",
                "adjudicated known-wrong for this commodity (matched on ruling core; "
                "the listing differs only by pack prefix or trailing size)", 1.0))

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

        # 4.5 BANKED VERDICT — a question this estate has already answered with
        # a model call or a human review. Checked here, and the placement is
        # deliberate.
        #
        # PLAN-price-state calls this "layer 0", meaning it should come before
        # everything. Implemented literally that would freeze the deterministic
        # rules: a newly added exclude pattern, category guard or known-wrong
        # ruling could never reach a question already banked, and this estate
        # ships those patterns constantly (13 rulings on 2026-08-20 alone).
        # The plan's stated GOAL is "the model is never asked a question twice
        # across runs" — which this position achieves exactly, while leaving
        # layers 1-4 free to overrule a banked verdict whenever the rules move.
        # Deterministic verdicts are never banked-and-reused: they are ~9s for
        # 120k rows, so recomputing them costs nothing and keeps them current.
        if self.bank:
            banked = self.bank.get((cc.node_id, norm))
            if banked:
                return self._tally(Verdict(banked["status"],
                                           f"banked: {banked['reason']}",
                                           banked["confidence"]))

        # 5. genuinely contested: no positive hit, but nothing rules it out.
        if not (allow_llm and self.use_llm and self.llm):
            # No confidence asserted: "no pattern matched" is not knowledge.
            return self._tally(Verdict("no_include_hit", "no include pattern matched"))
        return self._tally(self._llm_adjudicate(cc, name))

    def prior_rulings(self, cc: CompiledCommodity, name: str,
                      n_rej: int = 6, n_conf: int = 3,
                      authority: str = "adjudicated",
                      exclude_keys: frozenset[str] | set[str] | None = None) -> dict:
        """The most RELEVANT prior rulings for this commodity, as few-shot.

        Ranked by word overlap with the listing under judgement, because a
        rejection only teaches when it resembles the question: powdered-sugar
        carries 43 of them, and dumping all 43 would bury the one that matters
        and blow the prompt budget. Ties break toward the shorter name, which
        is usually the more general ruling.

        AUTHORITY (plan §3.1, 2026-08-22) decides who may testify:

          'adjudicated'  the shipped policy. Only adjudicated rulings — a human,
                         the Claude review lane, or a known-wrong node — are
                         cited as precedent. Model-consensus rows (helper + LLM,
                         phase 3) ride along in a separate TENTATIVE list.
                         Single-model rows are not shown at all.
          'all'          the pre-fix behaviour, kept ONLY so the ablation harness
                         can measure what the change cost or bought. Never ship
                         it: it is what let the model cite itself.
          'none'         no priors — the cold-start condition.

        `exclude_keys` holds norm_text() keys that must not appear among the
        examples. The measurement harness passes the case under test, because
        many gold cases ARE banked rulings and a case that appears among its own
        examples measures memorisation rather than learning.
        """
        if authority == "none" or not self._verdict_index:
            return {}
        pool = self._verdict_index.get(cc.node_id)
        if not pool:
            return {}
        want = set(re.findall(r"[a-z]{3,}", (name or "").lower()))
        skip = set(exclude_keys or ())
        if name:
            # A ruling on the very listing under judgement is never an example
            # for it, whatever the caller asked for.
            skip.add(norm_text(name))

        def rank(item):
            words = item[1]
            overlap = len(want & words) / max(len(want | words), 1)
            return (-overlap, len(item[0]))

        def usable(item, tiers):
            return item[3] in tiers and norm_text(item[0]) not in skip

        if authority == "all":
            precedent_tiers = None            # every tier, the old behaviour
            tentative_tiers: tuple = ()
        else:
            precedent_tiers = CITABLE_AS_PRECEDENT
            tentative_tiers = CITABLE_AS_TENTATIVE

        def pick(kind, tiers, limit):
            if tiers is None:
                items = (p for p in pool
                         if p[2] == kind and norm_text(p[0]) not in skip)
            else:
                items = (p for p in pool if p[2] == kind and usable(p, tiers))
            return [i[0] for i in sorted(items, key=rank)[:limit]]

        out = {"rejected": pick("reject", precedent_tiers, n_rej),
               "confirmed": pick("confirm", precedent_tiers, n_conf)}
        if tentative_tiers:
            out["tentative_rejected"] = pick("reject", tentative_tiers, n_rej)
            out["tentative_confirmed"] = pick("confirm", tentative_tiers, n_conf)
        return {k: v for k, v in out.items() if v}

    # The pre-2026-08-22 name, kept so nothing outside this file breaks.
    _prior_rulings = prior_rulings

    def _llm_adjudicate(self, cc: CompiledCommodity, name: str) -> Verdict:
        """Layer 5. The local model may REJECT a candidate or flag a probable
        match for review; it may never mint a price. See the module docstring
        for the bench decomposition that forced this asymmetry."""
        system, user = build_resolve_prompt(cc, name, self.prior_rulings(cc, name))
        try:
            parsed, res = self.llm.json_call(system, user, schema=RESOLVE_SCHEMA, max_tokens=400)
        except Exception as e:                                  # noqa: BLE001
            return Verdict("escalated", f"llm error: {e}", 0.0, escalate=True)

        verdict = str(parsed.get("verdict", "UNSURE")).upper()
        conf = float(parsed.get("confidence", 0.0) or 0.0)
        why = str(parsed.get("evidence", ""))[:400]
        meta = {
            "model": res.model,
            "prompt_version": PROMPT_VERSION,
            "input_hash": hash_obj([system, user]),
            "output_hash": res.output_hash,
            "llm_verdict": verdict,
            "completion_tokens": res.completion_tokens,
        }

        if verdict == "NO_MATCH" and not should_escalate(conf, self.escalate_below):
            # Rejection is the one power the local model holds outright: a wrong
            # rejection costs one empty cell, never a wrong published price.
            return Verdict("llm_rejected", f"llm: {why}", conf, meta=meta)
        if verdict == "MATCH" and not should_escalate(conf, self.escalate_below):
            # A confident MATCH is a LEAD, not a verdict. The bench's three
            # false matches carried conf 0.95-0.98, so no threshold cleanses a
            # local MATCH; only the Claude reviewer may upgrade this row to
            # llm_confirmed. Meanwhile it cannot price a cell.
            return Verdict("llm_match_unverified", f"llm MATCH (unverified): {why}",
                           conf, escalate=True, meta=meta)
        # UNSURE, or any answer below threshold -> escalate. Preferring a missed
        # merge over a false one, an escalation does NOT price a cell while it
        # waits for Claude.
        return Verdict("escalated", f"llm {verdict} conf={conf:.2f}: {why}", conf,
                       escalate=True, meta=meta)

    def _tally(self, v: Verdict) -> Verdict:
        self.stats[v.status] = self.stats.get(v.status, 0) + 1
        return v

    def _commit_verdicts(self, verdicts: dict, groups: dict, run: str, ts: str,
                         escalations: list) -> int:
        """Write a batch of question-verdicts out to every row that asked that
        question, and commit. MAIN THREAD ONLY — the worker pool does HTTP and
        nothing else, so the estate's single-writer rule is untouched.

        Returns the number of observation ROWS written (not questions)."""
        n = 0
        for key, v in verdicts.items():
            ids = groups[key]
            cid, name = key
            self.db.conn.executemany(
                "UPDATE price_observations SET match_status=?, match_reason=?, "
                "confidence=? WHERE id=?",
                [(v.status, v.reason, v.confidence, i) for i in ids])
            self.stats[v.status] = self.stats.get(v.status, 0) + len(ids)
            # Every MODEL judgment gets its own decision-log row. The aggregate
            # event says what a run did; only per-judgment rows with the model
            # id and prompt version let a bad verdict be attributed to the exact
            # model + prompt that produced it months later. One row per
            # QUESTION, carrying how many observations it settled.
            if run and v.meta:
                self.db.log_event(
                    run=run, timestamp=ts, etype="resolve",
                    model=v.meta["model"],
                    input_hash=v.meta["input_hash"],
                    output_hash=v.meta["output_hash"],
                    confidence=v.confidence,
                    decision=v.status,
                    detail={"observation": ids[0], "rows_settled": len(ids),
                            "commodity": cid, "product": name,
                            "llm_verdict": v.meta["llm_verdict"],
                            "prompt_version": v.meta["prompt_version"],
                            "reason": v.reason[:200]})
            if v.escalate:
                escalations.append({
                    "observation": ids[0], "commodity": cid,
                    "product": name, "reason": v.reason,
                    # One packet per QUESTION, not per row: the reviewer answers
                    # it once and the verdict applies to every row that shares it.
                    "rows_settled": len(ids),
                    # confirm_match: local model is confident this IS the
                    # commodity and asks the reviewer to upgrade the row.
                    # contested: nobody knows; adjudicate from scratch.
                    "kind": ("confirm_match" if v.status == "llm_match_unverified"
                             else "contested"),
                    "confidence": v.confidence,
                })
            n += len(ids)
        self.db.conn.commit()
        return n

    # -- bulk application --------------------------------------------------
    def resolve_pending(self, limit: int | None = None, run: str = "",
                        ts: str | None = None, allow_llm: bool = True,
                        progress=None, jobs: int = 1) -> dict:
        """Adjudicate pending observations, writing status back.

        Every DETERMINISTIC verdict (include_hit / excluded / category_excluded
        / no_include_hit, plus anything unadjudicated) is recomputed from the
        current rule set on every pass — see the comment at the selection below
        for the 2026-08-20 incident that made freezing them untenable. With the
        LLM enabled, the contested remainder (fresh verdict no_include_hit, no
        banked answer) goes to the model.

        Rows at llm_* / escalated / known_wrong are never re-selected: those
        verdicts are paid for (model time, reviewer time, or an adjudicated
        ruling) and re-rolling them would rewrite adjudication history. Their
        durability lives in question_verdicts and known-wrong.json, not here.

        DEDUPLICATION. `resolve()` is a pure function of
        (commodity_id, product_name) — nothing else about a row reaches it — so
        the SAME question is asked once and its verdict applied to every row
        that shares it. The contested set is 4.08x redundant (12,806 rows,
        3,139 distinct questions), because every capture of the same store
        listing re-poses the identical question. This is not only ~4x less
        work: it makes an identical question impossible to answer two different
        ways in one run, which sampling temperature alone could otherwise do.

        `jobs` > 1 issues the model calls concurrently against llama.cpp's
        parallel slots. Only the HTTP calls are threaded — every database write
        happens on this thread — so the single-writer rule is unchanged.
        """
        ts = ts or time.strftime("%Y-%m-%dT%H:%M:%S")
        self.stats = {}          # per-call, not per-Resolver: two runs on one
                                 # instance must not double-count in the log
        use_llm = allow_llm and self.use_llm and self.llm is not None
        # DETERMINISTIC verdicts are recomputed EVERY pass, never trusted from a
        # previous run. They cost ~2s for 120k rows, and freezing them meant a
        # new rule could not reach a row adjudicated before the rule existed:
        # the dried_carrier class guard landed on 2026-08-20 and freeze-dried
        # red onion, celery flakes and dried brussels-sprout crisps all kept
        # their old include_hit and kept pricing fresh-produce cells. The same
        # disease known-wrong rulings had, and the same cure — a rule change
        # binds everything, not just the future. What is NEVER re-rolled here:
        # llm_* and escalated (paid verdicts, banked in question_verdicts) and
        # known_wrong (absolute).
        pending = ("unadjudicated", "include_hit", "excluded",
                   "category_excluded", "no_include_hit")
        q = ("SELECT id, commodity_id, product_name FROM price_observations "
             f"WHERE match_status IN ({','.join('?' * len(pending))})")
        if limit:
            q += f" LIMIT {int(limit)}"
        rows = self.db.conn.execute(q, pending).fetchall()

        # -- group identical questions ------------------------------------
        groups: dict[tuple[str, str], list[str]] = {}
        meta_of: dict[tuple[str, str], sqlite3.Row] = {}
        for r in rows:
            key = (r["commodity_id"], r["product_name"] or "")
            groups.setdefault(key, []).append(r["id"])
            meta_of.setdefault(key, r)

        # -- pass 1: deterministic layers, in-process ----------------------
        verdicts: dict[tuple[str, str], Verdict] = {}
        contested: list[tuple[str, str]] = []
        for key in groups:
            cid, name = key
            try:
                # allow_llm=False here even in LLM mode: this pass settles what
                # the cheap layers can settle and isolates the contested set.
                v = self.resolve(cid, name, allow_llm=False)
            except KeyError:
                v = Verdict("escalated", "commodity node missing", 0.0, escalate=True)
            if use_llm and v.status == "no_include_hit":
                contested.append(key)
            else:
                verdicts[key] = v
        # The deterministic pass tallied by QUESTION; stats must count ROWS, so
        # rebuild the tally at write time below.
        self.stats = {}

        n = 0
        escalations: list[dict] = []
        # The deterministic verdicts are already known; bank them before any
        # model call, so an interrupted LLM pass never loses them.
        n += self._commit_verdicts(verdicts, groups, run, ts, escalations)

        # -- pass 2: the model, on the contested questions only -------------
        # Verdicts are CHECKPOINTED as they arrive, not held to the end. A run
        # over the full contested set takes ~48 minutes; banking nothing until
        # it finishes would mean a stop at minute 40 — a thermal abort, a
        # power cut, Ctrl-C — threw away 40 minutes of GPU time. Because
        # resolve_pending selects rows still in 'no_include_hit', a checkpointed
        # run is also RESUMABLE: re-running simply continues where it stopped.
        if contested:
            if progress:
                progress(f"    {len(contested)} contested questions "
                         f"({sum(len(groups[k]) for k in contested)} rows), "
                         f"{jobs} concurrent, checkpointing every {CHECKPOINT_EVERY}")

            def adjudicate(key):
                cid, name = key
                try:
                    return key, self._llm_adjudicate(self.commodity(cid), name)
                except Exception as e:                       # noqa: BLE001
                    return key, Verdict("escalated", f"llm error: {e}", 0.0, escalate=True)

            # commodity() caches per node id and reads the DB on a miss; warm
            # every entry on THIS thread so workers only ever read the dict.
            for cid, _ in contested:
                try:
                    self.commodity(cid)
                except KeyError:
                    pass

            batch: dict = {}
            done = 0

            def absorb(key, v):
                nonlocal batch, done, n
                batch[key] = v
                done += 1
                if len(batch) >= CHECKPOINT_EVERY:
                    n += self._commit_verdicts(batch, groups, run, ts, escalations)
                    batch = {}
                    if progress:
                        progress(f"    adjudicated {done}/{len(contested)} "
                                 f"(checkpointed)")

            if jobs > 1:
                with ThreadPoolExecutor(max_workers=jobs) as pool:
                    for key, v in pool.map(adjudicate, contested):
                        absorb(key, v)
            else:
                for key in contested:
                    absorb(*adjudicate(key))
            if batch:
                n += self._commit_verdicts(batch, groups, run, ts, escalations)

        if run:
            self.db.log_event(run=run, timestamp=ts, etype="resolve",
                              decision="resolve_pending",
                              detail={"n": n, "by_status": self.stats,
                                      "questions": len(groups),
                                      "model_calls": len(contested) if use_llm else 0,
                                      "jobs": jobs,
                                      "llm_enabled": bool(use_llm),
                                      "prompt_version": PROMPT_VERSION if use_llm else None,
                                      "escalations": len(escalations)})
        return {"resolved": n, "by_status": dict(self.stats), "escalations": escalations,
                "questions": len(groups),
                "model_calls": len(contested) if use_llm else 0}


def build_resolve_prompt(cc: CompiledCommodity, product_name: str,
                         examples: dict | None = None) -> tuple[str, str]:
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
    parts = [f"COMMODITY: {cc.label}",
             f"sold by: {cc.unit or 'unspecified'}",
             f"known surface patterns: {inc}"]

    # PRIOR RULINGS — this estate's own labelled history for THIS commodity.
    #
    # Until 2026-08-20 the model judged blind: it got the include patterns and
    # nothing else, while the human review packet for the same question carried
    # the excludes, the confirmed siblings and the known-wrong list. We were
    # teaching the reviewer and starving the model, with 2,551 adjudicated
    # rejections sitting unused (43 of them on powdered-sugar alone).
    #
    # These are not hints, they are decisions this board already made, and the
    # model's measured weakness is exactly the one they address: it asserts
    # MATCH on adjacent products at 0.95+ confidence. Showing it the adjacent
    # products that were already ruled out is the cheapest correction available,
    # and it costs no training run - the labels exist.
    #
    # WHOSE rulings (v5, 2026-08-22, plan section 3.1). v4 showed every banked
    # ruling, and 90% of them were the model's OWN unreviewed rejections - so
    # "already ruled" meant "you said so last week", and a wrong rejection
    # recruited its neighbours. Only ADJUDICATED rulings now speak with the
    # board's authority. Model-consensus rulings (helper + LLM, plan section 4)
    # appear in a separate list labelled tentative, so the model can weigh them
    # without mistaking them for decisions. Single-model rulings appear nowhere.
    # See graph/lib/authority.py and Resolver.prior_rulings.
    if examples:
        rejected = examples.get("rejected") or []
        confirmed = examples.get("confirmed") or []
        t_rejected = examples.get("tentative_rejected") or []
        t_confirmed = examples.get("tentative_confirmed") or []
        if rejected:
            parts.append("\nALREADY RULED **NOT** THIS COMMODITY by an adjudicator "
                         "(do not repeat these mistakes):")
            parts += [f"  - {r!r}" for r in rejected]
        if confirmed:
            parts.append("\nALREADY RULED **YES** by an adjudicator - this is what "
                         "belonging looks like:")
            parts += [f"  - {c!r}" for c in confirmed]
        if t_rejected or t_confirmed:
            parts.append("\nTENTATIVE, machine-only and NOT reviewed by an "
                         "adjudicator. Weigh these; they are not decided:")
            parts += [f"  - probably NOT this commodity: {r!r}" for r in t_rejected]
            parts += [f"  - probably IS this commodity: {c!r}" for c in t_confirmed]
    parts.append(f"\nSTORE PRODUCT LISTING: {product_name!r}\n")
    parts.append("Is this listing that commodity?")
    return system, "\n".join(parts)


def main() -> int:
    """CLI: adjudicate pending observations.

        python graph/pipeline/resolve.py              # deterministic layers, unadjudicated rows
        python graph/pipeline/resolve.py --llm        # + LLM over the contested set
                                                      #   (unadjudicated + no_include_hit)
        python graph/pipeline/resolve.py --llm --limit 500
    """
    import argparse
    import json as _json
    from graphdb import open_db

    ap = argparse.ArgumentParser(description="Resolve candidate rows to commodities")
    ap.add_argument("--llm", action="store_true",
                    help="consult the local model on rows the deterministic layers cannot settle")
    ap.add_argument("--limit", type=int, default=None)
    # COUPLED to tools/local-llm/serve.ps1 -Slots (4 since 2026-08-21; default here 4 since
    # 2026-08-22). More jobs than slots does not add throughput, it queues requests inside
    # llama-server and every queued call burns its client timeout waiting. Change both or neither.
    ap.add_argument("--jobs", type=int, default=4,
                    help="concurrent model calls; must be <= llama-server --parallel "
                         "slots (tools/local-llm/serve.ps1 -Slots, currently 4), else requests queue")
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
            # confidence must go too: a stale confidence on an 'unadjudicated'
            # row is an assertion nobody is currently making.
            db.conn.execute("UPDATE price_observations SET match_status='unadjudicated', "
                            "match_reason=NULL, confidence=NULL")
            db.conn.commit()
        r = Resolver(db, llm=llm, use_llm=bool(llm))
        t0 = time.time()
        out = r.resolve_pending(limit=args.limit, run=run, allow_llm=bool(llm),
                                progress=print, jobs=max(1, args.jobs))
        dt = time.time() - t0
        print(f"\nresolved {out['resolved']} rows in {dt:.1f}s "
              f"({out['questions']} distinct questions, "
              f"{out['model_calls']} model calls)")
        for k, v in sorted(out["by_status"].items(), key=lambda x: -x[1]):
            print(f"   {k:<20} {v}")
        if out["escalations"]:
            confirm = sum(1 for e in out["escalations"] if e.get("kind") == "confirm_match")
            print(f"\n   {len(out['escalations'])} rows escalated for Claude review "
                  f"({confirm} confirm-match, {len(out['escalations']) - confirm} contested)")
            qp = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                              "..", "..", "grocery", "escalation-queue.json"))
            # Append and dedupe by observation id — overwriting would silently
            # drop escalations a previous run queued and nobody has reviewed yet.
            prior = []
            if os.path.exists(qp):
                try:
                    with open(qp, encoding="utf-8-sig") as fh:
                        prior = _json.load(fh)
                except (_json.JSONDecodeError, OSError):
                    prior = []
            seen = {e.get("observation") for e in prior}
            merged = prior + [e for e in out["escalations"] if e["observation"] not in seen]
            with open(qp, "w", encoding="utf-8", newline="\n") as fh:
                _json.dump(merged, fh, indent=2, ensure_ascii=False)
            print(f"   queue now {len(merged)} rows at {qp}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
