"""D8 drill: the REAL cost pass, through Daemon.cost_engine, against a SCRATCH db\\costed.json.

Phase 3's first drain drill wrote two stalled rows into the LIVE batch ledger before --ledger existed.
The same hazard applies to db\\costed.json, which the live site's own pipeline reads. So this drill
points the cost engine at a scratch copy with -OutFile and proves three things:
  1. the pass really ran (it re-costs an existing published spec from the live boards),
  2. it went through the process-wide cost lock (cost_passes records it),
  3. the LIVE db\\costed.json is untouched before and after.
"""
import asyncio
import hashlib
import importlib.util
import os
import shutil
import sys
import tempfile

HERE = os.path.join(os.getcwd(), "meal-prep", "pipeline")
sys.path.insert(0, HERE)
spec = importlib.util.spec_from_file_location("hunt_daemon", os.path.join(HERE, "hunt-daemon.py"))
HD = importlib.util.module_from_spec(spec)
sys.modules["hunt_daemon"] = HD
spec.loader.exec_module(HD)

MP = os.path.dirname(HERE)
LIVE_COSTED = os.path.join(MP, "db", "costed.json")
COST_RECIPES = os.path.join(MP, "engine", "cost-recipes.ps1")
SLUG = sys.argv[1] if len(sys.argv) > 1 else "baked-cauliflower-mac-smoked-sausage"


def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def main():
    before = sha(LIVE_COSTED)
    tmp = tempfile.mkdtemp(prefix="d8-cost-drill-")
    scratch = os.path.join(tmp, "costed.json")
    shutil.copyfile(LIVE_COSTED, scratch)
    scratch_before = sha(scratch)
    scratch_mtime_before = os.path.getmtime(scratch)
    run_dir = os.path.join(tmp, "run")
    os.makedirs(run_dir, exist_ok=True)
    d = HD.Daemon(run_dir, "d8-cost-drill", quiet=False, costed_path=scratch)

    async def go():
        return await d.cost_engine(COST_RECIPES,
                                   ["-Slugs", [SLUG], "-OutFile", scratch,
                                    "-FlagsFile", os.path.join(tmp, "cost-flags.txt")])

    rc, out, err = asyncio.new_event_loop().run_until_complete(go())
    after = sha(LIVE_COSTED)
    scratch_after = sha(scratch)

    print("slug                 %s" % SLUG)
    print("rc                   %s" % rc)
    for line in (out or "").strip().splitlines():
        print("  | %s" % line)
    if (err or "").strip():
        print("  ! %s" % err.strip()[:400])
    print("cost passes recorded %d  (through Daemon.cost_engine, i.e. under the process-wide lock)"
          % len(d.cost_passes))
    import json as _json
    with open(scratch, "r", encoding="utf-8-sig") as fh:
        rows = _json.load(fh)
    rewrote = os.path.getmtime(scratch) > scratch_mtime_before
    # THE CONTENT HASH IS NOT THE TEST, AND THAT IS THE HONEST READING. A re-cost of an already-costed
    # recipe against unmoved boards produces the SAME numbers, so the bytes can legitimately match.
    # What is being proven is that the real engine wrote THIS file and not the live one: the mtime
    # moved, the file still parses at full catalog scale, and the live hash did not change.
    print("scratch costed.json  %s -> %s   rewritten=%s  rows=%d"
          % (scratch_before[:12], scratch_after[:12], rewrote, len(rows)))
    print("LIVE db\\costed.json  %s -> %s   %s"
          % (before[:12], after[:12], "UNTOUCHED" if before == after else "*** WRITTEN ***"))
    shutil.rmtree(tmp, ignore_errors=True)
    ok = (rc == 0 and len(d.cost_passes) == 1 and before == after and rewrote and len(rows) > 500)
    print("D8-COST-DRILL-%s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
