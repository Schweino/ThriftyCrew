"""The frozen, key-based held-out split of graph gold (W1 of design/PLAN-eval-heldout-and-hillclimb-2026-09-29.md).

    C:/Codex/Python312/python.exe graph/gold/gold_split.py              # VERIFY against the manifest, never write
    C:/Codex/Python312/python.exe graph/gold/gold_split.py --rewrite    # rewrite the manifest, loudly
    C:/Codex/Python312/python.exe graph/gold/gold_split.py --selftest

WHY. The learner's own failures became its own gold and then its own acceptance test, so a patch was scored on
the cases it was derived from. A held-out side the learner never sees is the only number that is not circular.

THE RULE. `split_of(row)` keys on the COMMODITY, never the row: a row-level split leaves the held-out side warm
(the reason `tools/local-llm/finetune-probe/split_holdout.py` gives). The key is the BARE id taken from the row's
NAMESPACED `commodity_node` (`commodity:staple:<id>` or `commodity:recipe:<id>`), so a staple and its recipe twin
land on the same side. A row whose `commodity_node` is not namespaced RAISES UnkeyedRow: it must never silently
land in train (.claude/rules/graph.md: a bare id returns an agreeing zero). The side is sha256(SALT + ":" + id),
first 8 hex digits mod 100, below PERCENT -> holdout. Keyed, never random (ms-08: sample by KEY).

WHY split_holdout.py's RULE IS NOT REUSED. `split_by_commodity` sorts the commodity names and shuffles them with a
seed, then takes the first 20%. Adding ONE commodity changes the list and so reassigns others between train and
holdout: it is stable for a frozen corpus and unstable under growth, which is the property gold needs most. A
per-key hash decides each commodity alone, so a new commodity never moves an old one. Its PURE reports
`leakage_report` and `containment_leaks` ARE reused: imported below for the near-twin report, never copied.

THE SPLIT IS DERIVED AT LOAD TIME, NEVER STORED ON A ROW. graph/learning/verdict_expiry.py fingerprints gold per
commodity; a stored split field would change every fingerprint and re-expire every verdict. split_of never
mutates its argument, and the self-test holds that with a CLEAN TWIN over the real `gold_fingerprints`.

THE MANIFEST (graph/gold/holdout-manifest.json, tracked) records salt, percent, the held-out commodity list and
the near-twin report. It is written ONCE. A plain run VERIFIES and never rewrites it (og-11 ratchet shape):
growth (a new held-out commodity, a commodity gone from gold) is spoken and is not a failure; a listed commodity
the rule now puts in train, or a salt or percent change, is a failure. `--rewrite` rewrites and says so.

ACCEPTANCE BAR (written 2026-09-29 before the run, in cases): over one named gold blob, for every counter in
score.py's `counts` (tp, fp, tn, fn, gold_match, gold_no_match, escalated, missing_node) and for the scored row
count, `--split train` plus `--split holdout` equals `--split all` EXACTLY, a difference of 0 cases. Anything else
fails W1. The held-out share of commodities should read 20% +/- 3 points; outside that is reported, not a fail.

SCOPE OF A CLEAN REPORT: SOUND for the manifest's own list (every listed commodity is re-derived under the rule);
it says nothing about near twins beyond the token and containment tests split_holdout.py defines.

Exit: 0 verified (or rewritten), 1 manifest disagrees with the rule, 2 self-test failure, 3 no manifest or no
gold to check (BLIND, never a pass).
"""
# Self-test: in-file fixtures plus the real gold_fingerprints and stage1 filters it imports.
# gate-inputs: graph\gold\gold_split.py, tools\local-llm\finetune-probe\split_holdout.py, graph\learning\verdict_expiry.py, graph\learning\stage1_analyze.py, graph\eval\audit_gold_circularity.py, graph\gold\seed_gold.py, graph\lib\graphdb.py, graph\lib\ids.py, graph\lib\llm.py, graph\lib\service_time.py
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
GOLD_PATH = os.path.join(HERE, "gold.jsonl")
MANIFEST = os.path.join(HERE, "holdout-manifest.json")
sys.path.insert(0, os.path.join(REPO, "tools", "local-llm", "finetune-probe"))

from split_holdout import leakage_report, containment_leaks   # noqa: E402  (pure; reused, never copied)

SALT = "tc-gold-holdout-2026-09-29"
PERCENT = 20
_NODE = re.compile(r"^commodity:(staple|recipe):([^:\s]+)$")
_PREFIX = re.compile(r"^commodity:(staple|recipe):")


class UnkeyedRow(ValueError):
    """A gold row whose commodity_node is not namespaced. Never defaulted to train."""


def key_of(row: dict) -> str:
    node = str(row.get("commodity_node") or "")
    m = _NODE.match(node)
    if not m:
        raise UnkeyedRow(f"gold row {row.get('id')!r} has commodity_node {node!r}, not "
                         f"commodity:staple:<id> or commodity:recipe:<id>; refusing to place it")
    return m.group(2)


def split_of_id(commodity_id: str) -> str:
    """Side of a commodity id, bare or namespaced (the prefix is stripped; the bare slug IS the key)."""
    cid = _PREFIX.sub("", str(commodity_id or ""))
    if not cid or ":" in cid:
        raise UnkeyedRow(f"commodity id {commodity_id!r} cannot be keyed")
    h = hashlib.sha256(f"{SALT}:{cid}".encode("utf-8")).hexdigest()
    return "holdout" if int(h[:8], 16) % 100 < PERCENT else "train"


def split_of(row: dict) -> str:
    """'train' or 'holdout' for one gold row. Pure: never mutates the row."""
    return split_of_id(key_of(row))


def holdout_labels(gold: list[dict]) -> set[str]:
    """Every name a held-out commodity goes by in gold: the bare node id AND the row's `commodity` label.
    They differ for a few rows (feta-cheese -> commodity:staple:feta), and an eval error carries the label."""
    out = set()
    for g in gold:
        if split_of(g) == "holdout":
            out.add(key_of(g))
            if g.get("commodity"):
                out.add(str(g["commodity"]))
    return out


def is_holdout_name(name: str, labels: set[str]) -> bool:
    """A learner-facing name (an error's commodity, a proposal target) is held out if gold says so under
    either spelling, or the rule puts it there. Over-filtering is the safe direction."""
    bare = _PREFIX.sub("", str(name or ""))
    if bare in labels:
        return True
    try:
        return split_of_id(bare) == "holdout"
    except UnkeyedRow:
        return False


def filter_split(gold: list[dict], which: str) -> list[dict]:
    if which == "all":
        return list(gold)
    if which not in ("train", "holdout"):
        raise ValueError(f"unknown split: {which}")
    return [g for g in gold if split_of(g) == which]


def load_gold(path: str = GOLD_PATH) -> list[dict]:
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as fh:
        return [json.loads(l) for l in fh if l.strip()]


def manifest_sha256(path: str = MANIFEST) -> str | None:
    if not os.path.exists(path):
        return None
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def build_manifest(gold: list[dict]) -> dict:
    train = [{"commodity": key_of(g)} for g in gold if split_of(g) == "train"]
    hold = [{"commodity": key_of(g)} for g in gold if split_of(g) == "holdout"]
    held = sorted({r["commodity"] for r in hold})
    return {
        "salt": SALT, "percent": PERCENT,
        "rule": "sha256(salt:bare_id)[:8] as int mod 100 < percent -> holdout; bare_id from commodity_node",
        "at_build": {"gold_rows": len(gold), "commodities": len({key_of(g) for g in gold}),
                     "commodities_holdout": len(held), "rows_holdout": len(hold), "rows_train": len(train)},
        "holdout_commodities": held,
        "near_twins": {
            "token_sharing": [{"holdout": c, "shared": s} for c, s in leakage_report(train, hold)],
            "containment": [{"holdout": c, "train": t} for c, t in containment_leaks(train, hold)],
        },
    }


def write_manifest(man: dict, path: str) -> None:
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(man, indent=1, sort_keys=True, ensure_ascii=False) + "\n")


def verify(gold: list[dict], path: str) -> tuple[int, list[str]]:
    """(exit, lines). Reads the manifest, never writes it."""
    if not os.path.exists(path):
        return 3, [f"BLIND: no manifest at {path}; create it once with --rewrite"]
    with open(path, encoding="utf-8") as fh:
        man = json.load(fh)
    lines, bad = [], 0
    if man.get("salt") != SALT or man.get("percent") != PERCENT:
        bad += 1
        lines.append(f"FAIL salt/percent: manifest {man.get('salt')}/{man.get('percent')}, code {SALT}/{PERCENT}")
    listed = list(man.get("holdout_commodities") or [])
    moved = [c for c in listed if split_of_id(c) != "holdout"]
    if moved:
        bad += 1
        lines.append(f"FAIL {len(moved)} of {len(listed)} listed held-out commodities now derive to train: {moved[:10]}")
    now_held = {key_of(g) for g in gold if split_of(g) == "holdout"}
    grown = sorted(now_held - set(listed))
    gone = sorted(set(listed) - {key_of(g) for g in gold})
    lines.append(f"listed {len(listed)}, re-derived holdout {len(listed) - len(moved)} of {len(listed)}; "
                 f"gold now holds {len(now_held)} held-out commodities")
    if grown:
        lines.append(f"growth (not a failure): {len(grown)} held-out commodities not in the manifest: {grown[:10]}")
    if gone:
        lines.append(f"growth (not a failure): {len(gone)} listed commodities have no gold row now: {gone[:10]}")
    return (1 if bad else 0), lines


def _selftest() -> int:
    import tempfile
    import shutil
    bad = 0
    n = 0

    def case(label, name, ok, got=""):
        nonlocal bad, n
        n += 1
        if not ok:
            bad += 1
        print(f"  {'ok  ' if ok else 'FAIL'} {label}: {name}" + ("" if ok else f"  got={got!r}"))

    ids = [f"item-{i:04d}" for i in range(1000)]

    # MUST FIRE: a bare commodity_node must not silently land in train.
    for label, node in (("bare id", "feta"), ("staple-less namespace", "commodity:feta"),
                        ("unknown namespace", "commodity:brand:feta"), ("missing", None)):
        try:
            split_of({"id": "g1", "commodity_node": node})
            case("MUST FIRE", f"a {label} commodity_node raises UnkeyedRow", False, "no raise")
        except UnkeyedRow:
            case("MUST FIRE", f"a {label} commodity_node raises UnkeyedRow", True)

    # CLEAN TWIN: staple and recipe twins land on the same side, over 1000 ids.
    same = all(split_of({"commodity_node": f"commodity:staple:{i}"})
               == split_of({"commodity_node": f"commodity:recipe:{i}"}) for i in ids)
    case("CLEAN TWIN", "staple and recipe twins of 1000 ids land on one side", same)

    # Bar written before the run: holdout share of 1000 synthetic ids is 20% +/- 3 points (170..230).
    held = sum(1 for i in ids if split_of_id(i) == "holdout")
    case("MUST NOT FIRE", "holdout share of 1000 ids within 170..230 (bar: 20% +/- 3)", 170 <= held <= 230, held)

    # Stable under growth: adding 200 new commodities moves none of the first 1000.
    before = {i: split_of_id(i) for i in ids}
    grown = ids + [f"new-{k}" for k in range(200)]
    after = {i: split_of_id(i) for i in grown}
    case("CLEAN TWIN", "adding 200 commodities reassigns none of 1000 old ones",
         all(after[i] == before[i] for i in ids))

    # CLEAN TWIN: split_of never mutates a row, so verdict_expiry's fingerprints are identical.
    sys.path.insert(0, os.path.join(REPO, "graph", "learning"))
    from verdict_expiry import gold_fingerprints
    rows = [{"id": f"g{k}", "commodity": i, "commodity_node": f"commodity:staple:{i}", "label": "MATCH",
             "product": f"p{k}", "kind": "match"} for k, i in enumerate(ids[:50])]
    fp0 = json.dumps(gold_fingerprints(rows, {}, "2026-09-29T00:00:00"), sort_keys=True)
    for r in rows:
        split_of(r)
    filter_split(rows, "holdout")
    holdout_labels(rows)
    fp1 = json.dumps(gold_fingerprints(rows, {}, "2026-09-29T00:00:00"), sort_keys=True)
    case("CLEAN TWIN", "gold fingerprints identical before and after splitting", fp0 == fp1)

    # train + holdout == all, in rows.
    case("CLEAN TWIN", "train rows + holdout rows == all rows",
         len(filter_split(rows, "train")) + len(filter_split(rows, "holdout")) == len(filter_split(rows, "all")) == 50)

    # Label twin: a held-out node whose row label differs is still recognised under the label.
    hid = next(i for i in ids if split_of_id(i) == "holdout")
    tid = next(i for i in ids if split_of_id(i) == "train")
    lab = holdout_labels([{"commodity": "long-label-name", "commodity_node": f"commodity:staple:{hid}"}])
    case("MUST FIRE", "a held-out row's differing label counts as held out", is_holdout_name("long-label-name", lab), lab)
    case("MUST NOT FIRE", "a train id is not held out", not is_holdout_name(tid, set()))

    # Stage 1: held-out failures never reach the learner; add_gold on a held-out commodity is refused.
    import stage1_analyze as s1
    errors = [{"type": "missed_merge", "commodity": hid, "product": "x"},
              {"type": "missed_merge", "commodity": tid, "product": "y"}]

    class _Row(dict):
        pass

    class _Conn:
        def execute(self, *a):
            class _C:
                def fetchone(_s):
                    return _Row(detail_json=json.dumps({"errors": errors}))
            return _C()

    class _Db:
        conn = _Conn()

    got = s1.gather_gold_failures(_Db(), 40, gold=[])
    case("MUST FIRE", "gather_gold_failures drops a held-out commodity's error", all(e["commodity"] != hid for e in got), got)
    case("CLEAN TWIN", "gather_gold_failures keeps a train commodity's error", any(e["commodity"] == tid for e in got), got)
    r_hold = s1.holdout_refusal({"kind": "add_gold", "target": hid}, set())
    r_ns = s1.holdout_refusal({"kind": "add_gold", "target": f"commodity:recipe:{hid}"}, set())
    case("MUST FIRE", "Stage 1 add_gold on a held-out commodity is refused with a reason", bool(r_hold) and hid in r_hold, r_hold)
    case("MUST FIRE", "the refusal holds for a namespaced recipe target", bool(r_ns), r_ns)
    case("MUST NOT FIRE", "Stage 1 add_gold on a train commodity passes", s1.holdout_refusal({"kind": "add_gold", "target": tid}, set()) is None)
    case("MUST NOT FIRE", "add_alias on a held-out commodity is not refused here",
         s1.holdout_refusal({"kind": "add_alias", "target": hid}, set()) is None)

    # Manifest: written once, a plain verify never writes, a moved commodity fails, absent is BLIND.
    tmp = tempfile.mkdtemp(prefix="gsplit-")
    try:
        mp = os.path.join(tmp, "m.json")
        code, _ = verify(rows, mp)
        case("MUST FIRE", "no manifest is BLIND (3), never a pass", code == 3, code)
        write_manifest(build_manifest(rows), mp)
        with open(mp, "rb") as fh:
            b0 = fh.read()
        code, _ = verify(rows + [{"commodity_node": f"commodity:staple:{hid}-new"}], mp)
        with open(mp, "rb") as fh:
            b1 = fh.read()
        case("MUST NOT FIRE", "a plain verify over grown gold passes", code == 0, code)
        case("CLEAN TWIN", "a plain verify leaves the manifest byte-identical", b0 == b1)
        m = json.loads(b0)
        m["holdout_commodities"].append(tid)
        write_manifest(m, mp)
        code, _ = verify(rows, mp)
        case("MUST FIRE", "a listed commodity that derives to train fails verify", code == 1, code)
        m["holdout_commodities"].remove(tid)
        m["salt"] = "other"
        write_manifest(m, mp)
        code, _ = verify(rows, mp)
        case("MUST FIRE", "a salt change fails verify", code == 1, code)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print(f"gold_split self-test: {n - bad} of {n} passed")
    print(f"GOLD-SPLIT-SELFTEST-COMPLETE selftest={'pass' if bad == 0 else 'fail'} cases={n}")
    return 0 if bad == 0 else 2


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--rewrite", action="store_true", help="rewrite the manifest (loud); a plain run only verifies")
    ap.add_argument("--manifest", default=MANIFEST)
    ap.add_argument("--gold", default=GOLD_PATH)
    a = ap.parse_args()
    if a.selftest:
        return _selftest()
    gold = load_gold(a.gold)
    if not gold:
        print(f"BLIND: no gold at {a.gold}")
        return 3
    if a.rewrite:
        man = build_manifest(gold)
        write_manifest(man, a.manifest)
        print(f"*** MANIFEST REWRITTEN: {a.manifest} ***")
        print(f"    {man['at_build']['commodities_holdout']} of {man['at_build']['commodities']} commodities held out, "
              f"{man['at_build']['rows_holdout']} of {man['at_build']['gold_rows']} rows; "
              f"token-sharing near twins {len(man['near_twins']['token_sharing'])}, "
              f"containment pairs {len(man['near_twins']['containment'])}")
        print(f"    sha256 {manifest_sha256(a.manifest)}")
        return 0
    code, lines = verify(gold, a.manifest)
    for l in lines:
        print(l)
    print(f"GOLD-SPLIT verify={'ok' if code == 0 else ('blind' if code == 3 else 'fail')} manifest_sha256={manifest_sha256(a.manifest)}")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
