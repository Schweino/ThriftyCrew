"""Executor + Recoverer — follow an immutable plan, exactly (Phase 3).

The Executor's contract, and the reason each clause exists:

* It follows the plan's topological order and NEVER edits the plan. It re-checks
  the plan hash before every step, so a plan mutated in flight is detected
  instead of obeyed.
* A failed step is retried up to the plan's declared limit and then ESCALATED.
  The Recoverer has no authority to invent a different step, skip a gate, or
  reorder work — those are the freedoms that make a pipeline unauditable.
* A failed BLOCKING step (every gate) stops the run. It does not "continue with
  warnings". The board not publishing is a recoverable Tuesday; the board
  publishing a wrong price is the thing this estate exists to prevent.
* Every transition is written to the decision log with its provenance, so the
  question "why did the run do that?" is answerable months later.

SHADOW MODE is the default and does not execute tool steps — it walks the plan,
runs the graph-side verify/model steps, and records what it WOULD have run. That
is what lets the graph prove itself against the parity and window gates without
touching the live daily chain.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

from graphdb import open_db, GRAPH_DIR, REPO_ROOT      # noqa: E402
from ids import hash_obj, run_id as make_run_id        # noqa: E402
from plan import Plan, Step, daily_pipeline_plan       # noqa: E402
from verifier import run_checks                        # noqa: E402

TRIAGE_QUEUE = os.path.join(REPO_ROOT, "grocery", "triage-queue.json")
LEARNING_QUEUE = os.path.join(REPO_ROOT, "grocery", "learning-queue.json")


class StepFailure(Exception):
    def __init__(self, step_id: str, detail: str):
        super().__init__(f"{step_id}: {detail}")
        self.step_id = step_id
        self.detail = detail


class Executor:
    def __init__(self, db, plan: Plan, shadow: bool = True, today: str | None = None):
        self.db = db
        self.plan = plan
        self.frozen = plan.to_dict()
        self.plan_hash = self.frozen["plan_hash"]
        self.shadow = shadow
        self.today = today or time.strftime("%Y-%m-%d")
        self.results: dict[str, dict] = {}

    # -- integrity ---------------------------------------------------------
    def _assert_plan_unchanged(self) -> None:
        current = self.plan.to_dict()
        if current["plan_hash"] != self.plan_hash:
            raise RuntimeError(
                "PLAN MUTATED MID-RUN — refusing to continue. The plan is immutable "
                "by contract; a changed hash means something rewrote it.")

    # -- step kinds --------------------------------------------------------
    def _run_verify(self, step: Step) -> dict:
        check = step.args.get("check")
        names = [check] if check else None
        return run_checks(self.db, names, today=self.today)

    def _run_tool(self, step: Step) -> dict:
        if self.shadow:
            return {"ok": True, "shadow": True,
                    "would_run": step.tool, "args": step.args}
        if not step.tool:
            return {"ok": True, "noop": True}
        path = os.path.join(REPO_ROOT, step.tool)
        if step.tool.endswith(".ps1"):
            cmd = ["powershell", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                   "-File", path]
        elif step.tool.endswith(".py"):
            cmd = [sys.executable, path]
        else:
            return {"ok": False, "error": f"unrunnable tool {step.tool!r}"}
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
        return {"ok": proc.returncode == 0, "returncode": proc.returncode,
                "stdout": proc.stdout[-2000:], "stderr": proc.stderr[-2000:]}

    def _run_model(self, step: Step) -> dict:
        """Graph-side model work. Safe in shadow: it writes only to the graph."""
        if step.tool and "resolve" in step.tool:
            sys.path.insert(0, os.path.join(GRAPH_DIR, "pipeline"))
            from resolve import Resolver                     # noqa: PLC0415
            from llm import LocalLLM                         # noqa: PLC0415
            llm = LocalLLM() if step.args.get("allow_llm") else None
            if llm and not llm.health():
                # The daily chain must survive the endpoint being down.
                llm = None
            r = Resolver(self.db, llm=llm, use_llm=bool(llm))
            out = r.resolve_pending(run=self.plan.run_id, allow_llm=bool(llm))
            return {"ok": True, **{k: v for k, v in out.items() if k != "escalations"},
                    "escalations": len(out.get("escalations", []))}
        return {"ok": True, "noop": True}

    def _run_commit(self, step: Step) -> dict:
        if self.shadow:
            return {"ok": True, "shadow": True, "would_run": "git commit + push"}
        return {"ok": True, "skipped": "commit handled by the legacy pipeline during transition"}

    DISPATCH = {"verify": _run_verify, "gate": _run_verify, "tool": _run_tool,
                "model": _run_model, "commit": _run_commit}

    # -- the loop ----------------------------------------------------------
    def execute(self) -> dict:
        ts = time.strftime("%Y-%m-%dT%H:%M:%S")
        max_retries = self.plan.escalation_policy.get("max_retries_per_step", 2)

        self.db.log_event(run=self.plan.run_id, timestamp=ts, etype="state_transition",
                          decision="run_start",
                          detail={"goal": self.plan.goal, "shadow": self.shadow,
                                  "plan_hash": self.plan_hash,
                                  "steps": len(self.plan.steps)})

        halted, escalations = None, []
        for step in self.plan.order():
            self._assert_plan_unchanged()

            # A step whose dependency failed is skipped, not attempted.
            unmet = [d for d in step.depends_on
                     if not self.results.get(d, {}).get("ok")]
            if unmet:
                self.results[step.id] = {"ok": False, "skipped": True, "unmet": unmet}
                self._log(step, "skipped", {"unmet_dependencies": unmet})
                continue

            limit = step.max_retries if step.max_retries is not None else max_retries
            attempt, result = 0, None
            while attempt <= limit:
                try:
                    fn = self.DISPATCH.get(step.type)
                    result = fn(self, step) if fn else {"ok": False,
                                                        "error": f"unknown step type {step.type}"}
                except Exception as e:                       # noqa: BLE001
                    result = {"ok": False, "error": f"{type(e).__name__}: {e}"}
                if result.get("ok"):
                    break
                attempt += 1
                if attempt <= limit:
                    self._log(step, "retry", {"attempt": attempt, "result": result})
                    time.sleep(min(2 ** attempt, 15))

            self.results[step.id] = result
            ok = bool(result.get("ok"))
            self._log(step, "ok" if ok else "failed", result)

            if not ok:
                # Retries exhausted: escalate per the plan's declared policy.
                esc = {"step": step.id, "type": step.type, "tool": step.tool,
                       "detail": result, "attempts": attempt,
                       "policy": self.plan.escalation_policy.get("on_exhaustion")}
                escalations.append(esc)
                self._log(step, "escalate", esc)
                if step.blocking:
                    halted = step.id
                    break

        status = "halted" if halted else "complete"
        self.db.log_event(run=self.plan.run_id, timestamp=ts, etype="state_transition",
                          decision=f"run_{status}",
                          detail={"halted_at": halted, "escalations": len(escalations),
                                  "results": {k: v.get("ok") for k, v in self.results.items()}})
        if escalations:
            self._queue(escalations)

        return {"status": status, "halted_at": halted, "results": self.results,
                "escalations": escalations, "plan_hash": self.plan_hash}

    def _log(self, step: Step, decision: str, detail: dict) -> None:
        etype = {"gate": "verify", "verify": "verify", "model": "resolve"}.get(
            step.type, "tool")
        if decision == "escalate":
            etype = "escalate"
        self.db.log_event(run=self.plan.run_id,
                          timestamp=time.strftime("%Y-%m-%dT%H:%M:%S"),
                          etype=etype, step_id=step.id, decision=decision,
                          output_hash=hash_obj(detail),
                          detail={k: v for k, v in detail.items()
                                  if k not in ("stdout", "stderr")})

    @staticmethod
    def _queue(escalations: list[dict]) -> None:
        """Append to the LOCAL escalation queue.

        Gitignored, exactly like triage-queue.json: producer and consumer are on
        the same PC so it never crosses the git-bus, and the bodies can carry raw
        store text.
        """
        path = LEARNING_QUEUE
        rows = []
        if os.path.exists(path):
            try:
                with open(path, encoding="utf-8-sig") as fh:
                    rows = json.load(fh)
            except (json.JSONDecodeError, OSError):
                rows = []
        rows.extend({**e, "queued_at": time.strftime("%Y-%m-%dT%H:%M:%S")}
                    for e in escalations)
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(rows, fh, indent=2, ensure_ascii=False)


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser(description="Execute the daily pipeline plan")
    ap.add_argument("--live", action="store_true",
                    help="actually run tool steps (default is SHADOW — recommended "
                         "until the Phase 3 parity gate passes)")
    ap.add_argument("--date", default=time.strftime("%Y-%m-%d"))
    ap.add_argument("--save-plan", action="store_true")
    args = ap.parse_args()

    stamp = time.strftime("%Y%m%dT%H%M%S")
    run = make_run_id("daily", stamp)
    plan = daily_pipeline_plan(run, time.strftime("%Y-%m-%dT%H:%M:%S"), args.date)

    if args.save_plan:
        p = plan.save(os.path.join(GRAPH_DIR, "runs", f"plan-{stamp}.json"))
        print(f"plan: {p}")

    mode = "LIVE" if args.live else "SHADOW"
    print(f"=== daily pipeline ({mode}) run={run} ===")
    print(f"    plan_hash={plan.to_dict()['plan_hash'][:16]}  steps={len(plan.steps)}\n")

    with open_db() as db:
        ex = Executor(db, plan, shadow=not args.live, today=args.date)
        out = ex.execute()

    for step in plan.order():
        r = out["results"].get(step.id)
        if r is None:
            mark, note = "----", "not reached"
        elif r.get("skipped"):
            mark, note = "SKIP", f"unmet: {r.get('unmet')}"
        elif r.get("ok"):
            mark = "PASS"
            note = "shadow" if r.get("shadow") else ""
            if step.type in ("gate", "verify") and "checks" in r:
                note = ", ".join(k for k, v in r["checks"].items() if not v["ok"]) or "all checks ok"
        else:
            mark, note = "FAIL", str(r.get("error") or r)[:90]
        print(f"  {mark}  {step.id:<22} {step.type:<7} {note}")

    print(f"\n  status: {out['status']}"
          + (f"   halted at: {out['halted_at']}" if out["halted_at"] else ""))
    if out["escalations"]:
        print(f"  {len(out['escalations'])} escalation(s) -> {LEARNING_QUEUE}")
    return 0 if out["status"] == "complete" else 1


if __name__ == "__main__":
    raise SystemExit(main())
