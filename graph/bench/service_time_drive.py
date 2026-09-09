"""I61: drive the local model with REAL resolve-shaped prompts so the service-time log fills.

WHY A DRIVER RATHER THAN THE PIPELINE. With the server finally up on 2026-09-09,
`resolve.py --emit-contested` reports 0 questions of 20,478 - the deterministic layers settle every
row - so a `--llm` run makes zero calls and records zero rows. That is not the server being down; it
is the pipeline having nothing to ask. This driver replays gold-set cases through the SAME prompt
builder and the SAME client at the SAME --jobs 4 the pipeline uses, so the rows in the log are real
round trips against the real server with the real prompt shape.

WHAT IT IS NOT: production arrival traffic. It is a closed-loop driver with four workers always busy,
so it measures SERVICE time, which is what I61 asked for, and says nothing about queue WAIT under the
pipeline's real arrivals. Stated here so the number is never read as more than it is.

It writes NO verdicts, NO graph state and NO baseline. Its only side effect is the service-time log
the client now appends to on every call.
"""
from __future__ import annotations

import argparse
import io
import json
import os
import random
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "graph", "lib"))
sys.path.insert(0, os.path.join(REPO, "graph", "pipeline"))

from llm import LocalLLM                                        # noqa: E402
import resolve as R                                             # noqa: E402
from graphdb import open_db                                     # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=60)
    ap.add_argument("--jobs", type=int, default=4, help="COUPLED to serve.ps1 -Slots, same as resolve.py")
    ap.add_argument("--seed", type=int, default=61)
    a = ap.parse_args()

    client = LocalLLM()
    if not client.health():
        print("i61-drive: BLIND - no llama-server on the endpoint; nothing measured")
        return 3

    rows = []
    with io.open(os.path.join(REPO, "graph", "gold", "gold.jsonl"), encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            name = d.get("product") or ""
            cid = d.get("commodity_node") or ""
            if name and cid:
                rows.append((cid, name))
    if len(rows) < a.n:
        print("i61-drive: BLIND - only %d usable gold row(s) for a run of %d" % (len(rows), a.n))
        return 3
    random.Random(a.seed).shuffle(rows)
    rows = rows[:a.n]

    db = open_db()
    resolver = R.Resolver(db, use_llm=True)

    # THE PROMPTS ARE BUILT ON THIS THREAD, ON PURPOSE. sqlite3 connections are not shared across
    # threads, so compiling a commodity inside a worker raises and the worker returns nothing - which
    # is how the first run of this driver reported 0 of 4 completed while the same call worked fine
    # single-threaded. Only the HTTP round trip belongs in the pool; that is also what is being timed.
    prompts = []
    skipped = 0
    for cid, name in rows:
        try:
            cc = resolver.commodity(cid)
        except Exception:                                        # noqa: BLE001
            skipped += 1
            continue
        prompts.append(R.build_resolve_prompt(cc, name, None))

    errs = []

    def one(su):
        system, user = su
        try:
            client.json_call(system, user, schema=R.RESOLVE_SCHEMA, max_tokens=400,
                             kind="i61-drive")
            return True
        except Exception as e:                                   # noqa: BLE001
            errs.append(str(e)[:160])
            return False

    with ThreadPoolExecutor(max_workers=a.jobs) as ex:
        done = list(ex.map(one, prompts))
    print("i61-drive: %d of %d prompt(s) completed at jobs=%d (%d commodity row(s) skipped, not in the graph)"
          % (sum(1 for d in done if d), len(prompts), a.jobs, skipped))
    for e in errs[:3]:
        print("  error: " + e)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
