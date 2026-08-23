"""
merge_adjudications.py - fold a reasoner's rulings on mined pairs into one adjudicated record.

WHY THIS STAGE EXISTS (2026-08-23). A mined near-miss is labelled by the candidate commodity's
regex, and the pairs a trained cross-encoder scores HIGHEST are exactly the ones most likely to be
mislabelled - a true match whose regex happens to reject it. Round-2 mining concentrates the corpus
on precisely those pairs, so it also concentrates the label error. The fix is not a better regex; it
is to ask a reasoner, which is the authority `authority.py` already recognises as `adjudicated` for
the Claude review lane.

WHAT THIS TOOL WILL NOT DO
  - It will not accept a ruling on a pair nobody asked about. Every verdict must join back to a row
    in the packet by (candidate, product), byte for byte. A reworded product name is a LOST row, not
    a fuzzy match, because the join key is what makes the ruling attributable at all.
  - It will not silently accept a partial answer. Missing rows are reported and counted; the record
    says how many of the asked questions came back.
  - It will not touch commodities.json. A YES verdict says an include pattern has a gap, which is a
    rule finding for a human and the learning loop, never an edit made by a corpus builder.

    python sidecar/merge_adjudications.py --packets scratch/adjudicate-*.json \
                                          --verdicts scratch/verdicts-*.json --by fable
"""
from __future__ import annotations
import argparse, glob, json, os, time

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
OUT = os.path.join(HERE, "out")


def log(m: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


def expand(patterns: list[str]) -> list[str]:
    out: list[str] = []
    for p in patterns:
        hits = sorted(glob.glob(p))
        if not hits:
            raise SystemExit(f"no file matches {p}")
        out.extend(hits)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Merge adjudicated rulings on mined pairs")
    ap.add_argument("--packets", nargs="+", required=True, help="the question files that were asked")
    ap.add_argument("--verdicts", nargs="+", required=True, help="the answer files that came back")
    ap.add_argument("--by", default="fable", help="who ruled (recorded, not interpreted)")
    ap.add_argument("--out", default=os.path.join(DATA, "mine-adjudicated.json"))
    a = ap.parse_args()

    # -- what was asked
    asked: dict[tuple[str, str], str] = {}          # (candidate, product) -> owner
    for p in expand(a.packets):
        for grp in json.load(open(p, encoding="utf-8-sig")):
            cid = grp["candidate_commodity"]["id"]
            own = grp["product_is_currently_priced_as"]["id"]
            for prod in grp["products"]:
                asked[(cid, prod)] = own
    log(f"asked: {len(asked)} product/commodity question(s) across {len(expand(a.packets))} packet(s)")

    # -- what came back
    seen: dict[tuple[str, str], dict] = {}
    unmatched, dupes = [], 0
    for p in expand(a.verdicts):
        for r in json.load(open(p, encoding="utf-8-sig")):
            key = (r.get("candidate") or "", r.get("product") or "")
            if key not in asked:
                unmatched.append(key)
                continue
            if key in seen:
                dupes += 1
                continue
            v = (r.get("verdict") or "").strip().upper()
            if v not in ("YES", "NO", "UNSURE"):
                unmatched.append(key)
                continue
            seen[key] = {"candidate": key[0], "owner": asked[key], "product": key[1],
                         "verdict": v, "why": (r.get("why") or "").strip(), "ruled_by": a.by}

    missing = [k for k in asked if k not in seen]
    counts = {v: sum(1 for r in seen.values() if r["verdict"] == v) for v in ("YES", "NO", "UNSURE")}
    log(f"answered: {len(seen)} of {len(asked)}   YES {counts['YES']}  NO {counts['NO']}  "
        f"UNSURE {counts['UNSURE']}")
    if missing:
        log(f"WARNING {len(missing)} question(s) came back with no ruling - they keep their regex "
            f"label, which is the status quo and not a new claim")
    if unmatched:
        log(f"WARNING {len(unmatched)} verdict(s) did not join to any question and were DROPPED "
            f"(a reworded product name is a lost row, never a fuzzy match)")
    if dupes:
        log(f"WARNING {dupes} duplicate verdict(s) ignored (first wins)")

    payload = {
        "generated": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "ruled_by": a.by,
        "asked": len(asked), "answered": len(seen),
        "unanswered": len(missing), "unmatched_dropped": len(unmatched), "duplicates": dupes,
        "counts": counts,
        "authority": "adjudicated - a reasoner's ruling, the tier authority.py gives the review "
                     "lane. It overrides the mined pair's regex label in build_pair_corpus.py.",
        "verdicts": sorted(seen.values(), key=lambda r: (r["candidate"], r["product"])),
    }
    with open(a.out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(payload, f, indent=1, ensure_ascii=False)
    log(f"wrote {a.out}")

    # -- THE RULE GAPS. A YES means the candidate commodity's own include patterns reject a product
    #    that IS that commodity. That is a finding for a human and for the learning loop; nothing
    #    here edits a rule.
    yes = [r for r in seen.values() if r["verdict"] == "YES"]
    if yes:
        os.makedirs(OUT, exist_ok=True)
        gp = os.path.join(OUT, "mined-rule-gaps.json")
        with open(gp, "w", encoding="utf-8", newline="\n") as f:
            json.dump({"generated": payload["generated"], "ruled_by": a.by,
                       "what": "the candidate commodity's include patterns reject a product a "
                               "reasoner says IS that commodity - a rule gap, reported not applied",
                       "gaps": yes}, f, indent=1, ensure_ascii=False)
        log(f"wrote {gp} ({len(yes)} rule gap(s) - reported, never applied)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
