"""freeze_eval.py - snapshot the evaluation set so a before/after measures the MODEL, not the shelf.

    python sidecar/freeze_eval.py                    # snapshot today under data/frozen/<today>/
    python sidecar/freeze_eval.py --name phase3      # a named snapshot
    python sidecar/freeze_eval.py --list

WHY THIS EXISTS
---------------
`commodity_text()` is "label + up to 5 of the products the board currently accepts". That is the
right definition for the nightly sweep, which is scoring today's board - and it means every score in
the estate is a function of what the shelf looked like that morning.

Measured 2026-08-22, same pinned model, same positives.json, same negatives.json, changing ONLY the
commodity text:

    label + exemplars    TASK A AUC 0.9705    17/25 known-wrong caught at a 100/2816 budget
    label alone          TASK A AUC 0.7921     0/25

And with byte-identical eval files, backtest.py reported 24/24 recall on 2026-08-01 and 17/25 on
2026-08-22. The model did not change. The board did.

PLAN-local-matching section 6 wants a fine-tuned cross-encoder that "beats stock on holdout AUC".
Run on two different days, that comparison is dominated by exemplar churn, and the churn is bigger
than any fine-tune is likely to buy. So a comparison uses a frozen snapshot, passed to BOTH sides:

    python sidecar/backtest.py --defs sidecar/data/frozen/<name>/commodity-defs.json
    python sidecar/backtest.py --defs sidecar/data/frozen/<name>/commodity-defs.json \\
                               --reranker <candidate> --tag ft-v1

WHAT IS SNAPSHOT, AND WHY IT IS TRACKED
---------------------------------------
The commodity definitions and every labelled eval file - the positives, the dramatic negatives, the
adjudicated GOLD negatives, and the mined near-misses if they have been labelled. `sidecar/data/` is
gitignored as a working directory, and `.gitignore` un-ignores `data/frozen/` specifically, for the
reason the file's own comments give about the gold set: an evaluation record that does not outlive
the machine that produced it is not an evaluation record. Roughly 850 KB a snapshot.

A snapshot is IMMUTABLE. Re-freezing under an existing name is refused; take a new one.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
FROZEN = os.path.join(DATA, "frozen")

# The eval set is these files and nothing else. A file that is missing is recorded as missing rather
# than quietly skipped: a snapshot that silently lacks the GOLD negatives would look complete and
# would grade a candidate on the easy negatives alone.
FILES = [
    ("commodity-defs.json", True,  "label + today's accepted exemplars - THE drifting input"),
    ("positives.json",      True,  "accepted board pairs (backtest.py's positive class)"),
    ("negatives.json",      True,  "the 25 dramatic negatives (Phase 1's set)"),
    ("eval-positives.json", False, "accepted board pairs (hardeval.py's positive class)"),
    ("negatives-gold.json", False, "the adjudicated wrong-product rulings - the class that matters"),
    ("mine-labelled.json",  False, "mined near-misses, regex-labelled (empty to date)"),
]


def sha(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()[:16]


def do_list() -> int:
    if not os.path.isdir(FROZEN):
        print("no snapshots yet")
        return 0
    for name in sorted(os.listdir(FROZEN)):
        mp = os.path.join(FROZEN, name, "manifest.json")
        if not os.path.exists(mp):
            continue
        with open(mp, encoding="utf-8") as f:
            m = json.load(f)
        miss = [k for k, v in m["files"].items() if v is None]
        print(f"{name:<24} {m['frozen']}  {len(m['files']) - len(miss)} file(s)"
              f"{'  MISSING: ' + ', '.join(miss) if miss else ''}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--name", default=None,
                    help="snapshot name (default: today's date)")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()
    if args.list:
        return do_list()

    name = args.name or time.strftime("%Y-%m-%d")
    dest = os.path.join(FROZEN, name)
    if os.path.exists(dest):
        # A snapshot is the fixed point a comparison is anchored to. Silently overwriting one would
        # invalidate every report that cites it, retroactively and invisibly.
        print(f"REFUSED: {dest} already exists. A snapshot is immutable - pick another --name.")
        return 2
    os.makedirs(dest, exist_ok=True)

    manifest = {"frozen": time.strftime("%Y-%m-%dT%H:%M:%S"), "name": name, "files": {}, "notes": {}}
    missing_required = []
    for fname, required, note in FILES:
        src = os.path.join(DATA, fname)
        manifest["notes"][fname] = note
        if not os.path.exists(src):
            manifest["files"][fname] = None
            if required:
                missing_required.append(fname)
            print(f"  -- {fname:<24} MISSING")
            continue
        shutil.copy2(src, os.path.join(dest, fname))
        d = sha(src)
        manifest["files"][fname] = {"sha256_16": d, "bytes": os.path.getsize(src)}
        print(f"  ok {fname:<24} {d}  {os.path.getsize(src):,} bytes")

    with open(os.path.join(dest, "manifest.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(manifest, f, indent=2)

    if missing_required:
        print(f"\nINCOMPLETE: missing {', '.join(missing_required)} - this snapshot cannot anchor a "
              f"backtest comparison. Run grocery\\export-identity-eval.ps1 and re-freeze.")
        return 3
    print(f"\nfroze {dest}")
    print("use it on BOTH sides of any comparison:")
    print(f"  python sidecar/backtest.py --defs sidecar/data/frozen/{name}/commodity-defs.json")
    print(f"  python sidecar/hardeval.py --stage score "
          f"--defs sidecar/data/frozen/{name}/commodity-defs.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
