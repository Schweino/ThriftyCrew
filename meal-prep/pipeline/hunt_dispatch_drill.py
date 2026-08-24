"""
hunt_dispatch_drill.py - the section 4.1a adapter drill (D9's phase-3 gate item).

    python hunt_dispatch_drill.py --headless          # dispatch every agent through the adapter
    python hunt_dispatch_drill.py --emit-twin         # regenerate the Workflow twin script
    python hunt_dispatch_drill.py --diff <twin.json>  # merge the twin's result and write the artifact

WHAT THE GATE ASKS FOR, in section 4.1a's own words: "the phase-3 drill must dispatch every agent type
once against scratch inputs and (a) diff its behavior against a Workflow-dispatched twin, (b) measure
the fixed per-call overhead - a headless invocation loads project context (CLAUDE.md, settings, memory)
on every call, and whether that costs more or less than a Workflow subagent's per-dispatch overhead is
a question for the drill's measurement, not for this document's assumption."

Both roads read `hunt-dispatch-drill.json`, so neither can quietly ask a different question. The
prompts are deliberately tiny: with a ~60-token question, the dispatch's input token count IS the fixed
overhead, which is the number the plan wants and the only way to get it without a second baseline run.

WHAT A BEHAVIOR DIFF IS HERE. Two runs of the same model do not write the same sentence, so diffing
prose would measure temperature. The spec names, per dispatch, the `keys` whose VALUES must agree -
the verdicts, the enum answers, the counts. Everything else is recorded and read by a human.

EXIT CODES (section 4.5): 0 clean / 1 findings / 2 could-not-run. Marker DISPATCH-DRILL-COMPLETE.
INTERPRETER: C:\\Codex\\Python312\\python.exe.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MP = os.path.dirname(HERE)
REPO = os.path.dirname(MP)
sys.path.insert(0, HERE)

import harvest                                                   # noqa: E402
import hunt_dispatch                                             # noqa: E402
import hunt_lib                                                  # noqa: E402

SPEC = os.path.join(HERE, "hunt-dispatch-drill.json")
TWIN_JS = os.path.join(HERE, "hunt-dispatch-twin.js")
OUT_DIR = os.path.join(MP, "out", "d9-gate")
HEADLESS_OUT = os.path.join(OUT_DIR, "adapter-drill-headless.json")
ARTIFACT = os.path.join(OUT_DIR, "adapter-drill.json")

_TWIN_BEGIN = "// >>> GENERATED-SPEC-BEGIN"
_TWIN_END = "// >>> GENERATED-SPEC-END"


def load_spec(path=None):
    with open(path or SPEC, "r", encoding="utf-8-sig") as f:
        return json.load(f)


def dig(obj, path):
    """`decisions.0.slug` / `ingredients.length`. Returns a sentinel string when the path does not
    exist, so a missing field DIFFERS from a present one rather than both reading as None."""
    cur = obj
    for part in path.split("."):
        if part == "length":
            return len(cur) if isinstance(cur, (list, str, dict)) else "<not-countable>"
        if isinstance(cur, list):
            try:
                cur = cur[int(part)]
            except (ValueError, IndexError):
                return "<absent>"
        elif isinstance(cur, dict):
            if part not in cur:
                return "<absent>"
            cur = cur[part]
        else:
            return "<absent>"
    return cur


def run_headless(spec, only=None, reconstruct=False):
    rows = []
    methods, _u = harvest.load_methods()
    allowed = set(methods) | {"any"}
    for d in spec["dispatches"]:
        if only and d["agent"] not in only:
            continue
        validator = None
        schema = d.get("schema")
        if d.get("decide"):
            schema = hunt_lib.DECIDE
            validator = (lambda p: hunt_lib.validate_decide(p, methods=allowed))
        print("  dispatching %-26s ..." % d["agent"], end="", flush=True)
        t0 = time.time()
        r = hunt_dispatch.dispatch(d["agent"], d["prompt"], schema=schema, validator=validator,
                                   reconstruct=reconstruct)
        row = r.as_dict()
        row["road"] = "reconstruct" if reconstruct else "agent-flag"
        row["keys"] = {k: dig(r.payload, k) for k in (d.get("keys") or [])} if r.payload else {}
        rows.append(row)
        print(" %s  %5.1fs  in=%-7d out=%-5d $%.4f%s"
              % ("ok " if r.ok else "FAIL", time.time() - t0, r.tokens_in, r.tokens_out, r.cost_usd,
                 "  RE-ASKED" if r.reasked else ""))
        for f in r.findings:
            print("      FINDING  " + f)
        if not r.ok:
            print("      %s: %s" % (r.failure, r.detail[:200]))
    return rows


def emit_twin(spec=None, out_path=None):
    """Rewrite the twin's embedded spec. Same generator discipline as hunt-lib-parity.js: a workflow
    script cannot read the repo, so the copy is written by a machine rather than by a person."""
    spec = spec or load_spec()
    out_path = out_path or TWIN_JS
    with open(out_path, "r", encoding="utf-8") as f:
        lines = f.read().split("\n")
    b = [i for i, ln in enumerate(lines) if ln.startswith(_TWIN_BEGIN)]
    e = [i for i, ln in enumerate(lines) if ln.startswith(_TWIN_END)]
    if not b or not e or e[0] <= b[0]:
        raise RuntimeError("%s has no generated spec region" % out_path)
    lines[b[0] + 1:e[0]] = ["const SPEC = " + json.dumps(spec, ensure_ascii=False)]
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))
    return out_path, len(spec["dispatches"])


def twin_spec_state(spec=None, out_path=None):
    try:
        spec = spec or load_spec()
        out_path = out_path or TWIN_JS
        with open(out_path, "r", encoding="utf-8") as f:
            text = f.read()
        b = text.find(_TWIN_BEGIN)
        e = text.find(_TWIN_END)
        if b < 0 or e < 0:
            return False, "the twin has no generated spec region"
        body = text[text.find("\n", b) + 1:e].strip()
        if not body.startswith("const SPEC = "):
            return False, "the twin carries no embedded spec - run --emit-twin"
        if json.loads(body[len("const SPEC = "):]) != spec:
            return False, "the twin's embedded spec differs from hunt-dispatch-drill.json"
        return True, "%d dispatches" % len(spec["dispatches"])
    except Exception as ex:                                       # noqa: BLE001
        return False, "could not read the twin's embedded spec (%s)" % ex


def diff(spec, headless_rows, twin_rows):
    """Per agent: did both roads answer, and do the named keys agree?"""
    by_agent_t = {r["agent"]: r for r in twin_rows}
    by_agent_h = {r["agent"]: r for r in headless_rows}
    out, findings = [], []
    for d in spec["dispatches"]:
        a = d["agent"]
        h, t = by_agent_h.get(a), by_agent_t.get(a)
        row = {"agent": a,
               "headless_ok": bool(h and h.get("ok")), "twin_ok": bool(t and t.get("ok")),
               "headless_keys": (h or {}).get("keys") or {}, "twin_keys": (t or {}).get("keys") or {},
               "headless_tokens_in": (h or {}).get("tokens_in"),
               "headless_tokens_out": (h or {}).get("tokens_out"),
               "headless_cache_read": (h or {}).get("cache_read"),
               "headless_cache_creation": (h or {}).get("cache_creation"),
               "headless_seconds": (h or {}).get("seconds"),
               "headless_cost_usd": (h or {}).get("cost_usd"),
               "twin_tokens_in": (t or {}).get("tokens_in"),
               "twin_tokens_out": (t or {}).get("tokens_out"),
               "headless_reasked": (h or {}).get("reasked"),
               "twin_reasked": (t or {}).get("reasked"),
               "headless_findings": (h or {}).get("findings") or [],
               "disagreements": []}
        if h is None:
            findings.append("%s: the headless road produced no row at all" % a)
        if t is None:
            findings.append("%s: the twin produced no row at all" % a)
        if h and not h.get("ok"):
            findings.append("%s: the headless dispatch returned NO VERDICT (%s: %s)"
                            % (a, h.get("failure"), (h.get("detail") or "")[:120]))
        if t and not t.get("ok"):
            findings.append("%s: the twin returned NO VERDICT" % a)
        for k in d.get("keys") or []:
            hv, tv = row["headless_keys"].get(k, "<absent>"), row["twin_keys"].get(k, "<absent>")
            if row["headless_ok"] and row["twin_ok"] and hv != tv:
                row["disagreements"].append({"key": k, "headless": hv, "twin": tv})
                findings.append("%s: the two roads disagree on `%s` (headless %r, twin %r)"
                                % (a, k, hv, tv))
        for f in row["headless_findings"]:
            findings.append("%s: %s" % (a, f))
        out.append(row)
    return out, findings


def overhead(headless_rows, twin_rows):
    """The fixed per-call overhead, both roads. `tokens_in` on a ~60-token prompt IS the fixed part."""
    def stats(rows, key):
        vals = [r[key] for r in rows if isinstance(r.get(key), (int, float)) and r.get(key)]
        if not vals:
            return None
        vals.sort()
        return {"n": len(vals), "min": vals[0], "median": vals[len(vals) // 2], "max": vals[-1],
                "mean": round(sum(vals) / len(vals), 1)}
    return {
        "headless_tokens_in": stats(headless_rows, "tokens_in"),
        "headless_cache_creation": stats(headless_rows, "cache_creation"),
        "headless_cache_read": stats(headless_rows, "cache_read"),
        "headless_seconds": stats(headless_rows, "seconds"),
        "headless_cost_usd": stats(headless_rows, "cost_usd"),
        "twin_tokens_in": stats(twin_rows, "tokens_in"),
        "twin_tokens_out": stats(twin_rows, "tokens_out"),
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description="the section 4.1a adapter drill")
    ap.add_argument("--headless", action="store_true")
    ap.add_argument("--reconstruct", action="store_true",
                    help="run the headless side down section 4.1a's original road instead")
    ap.add_argument("--only", default="", help="comma-separated agent names")
    ap.add_argument("--emit-twin", dest="emit_twin", action="store_true")
    ap.add_argument("--diff", default="", help="path to the twin's saved result JSON")
    ap.add_argument("--out", default="")
    a = ap.parse_args(argv)
    spec = load_spec()
    os.makedirs(OUT_DIR, exist_ok=True)

    if a.emit_twin:
        p, n = emit_twin(spec)
        print("dispatch drill --emit-twin: %s  (%d dispatches)" % (os.path.basename(p), n))
        print("DISPATCH-DRILL-COMPLETE")
        return hunt_lib.EXIT_CLEAN

    if a.headless:
        only = set(x.strip() for x in a.only.split(",") if x.strip())
        print("adapter drill, headless road (%s):"
              % ("reconstruct - section 4.1a as written" if a.reconstruct else "--agent"))
        rows = run_headless(spec, only or None, a.reconstruct)
        out = a.out or HEADLESS_OUT
        if only and os.path.exists(out):
            # MERGE, never replace. A re-run of one agent that wiped the other nine would leave a
            # drill report claiming a coverage it no longer has.
            with open(out, "r", encoding="utf-8-sig") as f:
                prev = json.load(f)
            kept = [r for r in prev.get("rows") or [] if r["agent"] not in only]
            order = [d["agent"] for d in spec["dispatches"]]
            rows = sorted(kept + rows, key=lambda r: order.index(r["agent"])
                          if r["agent"] in order else 999)
        with open(out, "w", encoding="utf-8") as f:
            json.dump({"generated": time.strftime("%Y-%m-%dT%H:%M:%S"),
                       "road": "reconstruct" if a.reconstruct else "agent-flag",
                       "rows": rows}, f, indent=1, ensure_ascii=False)
        print("  -> %s" % out)
        print("DISPATCH-DRILL-COMPLETE")
        return hunt_lib.EXIT_FINDINGS if any(not r["ok"] for r in rows) else hunt_lib.EXIT_CLEAN

    if a.diff:
        if not os.path.exists(a.diff):
            print("dispatch drill: CANNOT RUN - no twin result at %s" % a.diff)
            print("DISPATCH-DRILL-COMPLETE")
            return hunt_lib.EXIT_CANNOT_RUN
        with open(HEADLESS_OUT, "r", encoding="utf-8-sig") as f:
            head = json.load(f)
        with open(a.diff, "r", encoding="utf-8-sig") as f:
            twin = json.load(f)
        twin_rows = twin.get("rows") if isinstance(twin, dict) else twin
        rows, findings = diff(spec, head["rows"], twin_rows or [])
        art = {"generated": time.strftime("%Y-%m-%dT%H:%M:%S"),
               "what": "section 4.1a adapter drill: every agent type once, both roads, same prompts",
               "headless_road": head.get("road"),
               "dispatches": len(rows),
               "overhead": overhead(head["rows"], twin_rows or []),
               "rows": rows, "findings": findings,
               "headless_detail": head["rows"], "twin_detail": twin_rows}
        with open(a.out or ARTIFACT, "w", encoding="utf-8") as f:
            json.dump(art, f, indent=1, ensure_ascii=False)
        print("adapter drill: %d dispatch(es), %d finding(s)" % (len(rows), len(findings)))
        for r in rows:
            print("  %-26s headless %-4s twin %-4s  in=%-7s out=%-5s %5.1fs  %s"
                  % (r["agent"], "ok" if r["headless_ok"] else "FAIL",
                     "ok" if r["twin_ok"] else "FAIL", r["headless_tokens_in"],
                     r["headless_tokens_out"], r["headless_seconds"] or 0,
                     "AGREE" if not r["disagreements"] else
                     ("DIFFER on " + ", ".join(d["key"] for d in r["disagreements"]))))
        for f in findings:
            print("  FINDING  " + f)
        print("  -> %s" % (a.out or ARTIFACT))
        print("DISPATCH-DRILL-COMPLETE")
        return hunt_lib.EXIT_FINDINGS if findings else hunt_lib.EXIT_CLEAN

    ap.print_help()
    print("DISPATCH-DRILL-COMPLETE")
    return hunt_lib.EXIT_CANNOT_RUN


if __name__ == "__main__":
    sys.exit(main())
