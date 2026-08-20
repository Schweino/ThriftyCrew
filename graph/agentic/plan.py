"""Immutable plan format for agentic workflows (plan §8, Phase 3).

The Planner emits a plan ONCE, at the top of a run. The Executor follows it
exactly. Neither a model nor the Recoverer may rewrite it mid-run — a step can be
retried within its declared limit or escalated, and that is all.

That immutability is the entire point. A pipeline that lets a model rewrite its
own plan after a failure cannot be audited afterwards, because the thing it
actually did is no longer the thing it said it would do. Freezing the plan (and
hashing it) means the decision log can be replayed against it.

The daily plan mirrors the REAL chain in grocery/check-ad-cycles.ps1:
    ad pulls -> compare-deals -> guards -> publish deals page -> cost-recipes
    -> compute-v2 -> top5-weekly -> rotate-free-dinners -> commit/push
"""

from __future__ import annotations

import json
import os
import sys
from dataclasses import asdict, dataclass, field

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))

from ids import hash_obj                       # noqa: E402


@dataclass
class Step:
    id: str
    type: str                       # tool | verify | gate | model | commit
    depends_on: list[str] = field(default_factory=list)
    tool: str | None = None         # the script/command this step runs
    args: dict = field(default_factory=dict)
    description: str = ""
    # A gate step is BLOCKING: the run stops rather than publishing past a
    # failed gate. This is how Omaha-identity and current-week validity keep
    # their teeth under the new orchestration.
    blocking: bool = True
    max_retries: int | None = None


@dataclass
class Plan:
    run_id: str
    created_at: str
    goal: str
    steps: list[Step]
    escalation_policy: dict = field(default_factory=lambda: {
        "max_retries_per_step": 2,
        "on_exhaustion": "triage_queue_or_learning_queue",
    })

    def to_dict(self) -> dict:
        d = {
            "run_id": self.run_id,
            "created_at": self.created_at,
            "goal": self.goal,
            "steps": [asdict(s) for s in self.steps],
            "escalation_policy": self.escalation_policy,
        }
        # The hash covers everything above; the Executor re-checks it before each
        # step, so an in-flight mutation is detected rather than silently obeyed.
        d["plan_hash"] = hash_obj(d)
        return d

    def save(self, path: str) -> str:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(self.to_dict(), fh, indent=2, ensure_ascii=False)
        return path

    def step(self, step_id: str) -> Step | None:
        return next((s for s in self.steps if s.id == step_id), None)

    def order(self) -> list[Step]:
        """Topological order. Raises on a cycle — a cyclic plan is a bug in the
        Planner and must never reach the Executor."""
        done: set[str] = set()
        out: list[Step] = []
        remaining = list(self.steps)
        while remaining:
            ready = [s for s in remaining if all(d in done for d in s.depends_on)]
            if not ready:
                stuck = [s.id for s in remaining]
                raise ValueError(f"plan has a dependency cycle or missing step: {stuck}")
            for s in ready:
                out.append(s)
                done.add(s.id)
                remaining.remove(s)
        return out


def daily_pipeline_plan(run_id: str, created_at: str, date: str) -> Plan:
    """The daily grocery pipeline, as an explicit state graph.

    Mirrors check-ad-cycles.ps1. Every gate that exists today stays a BLOCKING
    step here; the redesign changes how the chain is orchestrated and audited,
    never what it is allowed to publish.
    """
    S = Step
    steps = [
        S("pull_ads", "tool", [], "grocery/check-ad-cycles.ps1",
          {"stage": "ad-pulls", "date": date},
          "Per-store weekly ad pulls for any store whose cycle rolled over"),

        S("gate_ad_window", "gate", ["pull_ads"], "graph/agentic/verifier.py",
          {"check": "ad_window"},
          "Every pulled ad must fall inside the store's CURRENT week window"),

        S("gate_omaha", "gate", ["pull_ads"], "graph/agentic/verifier.py",
          {"check": "omaha_identity"},
          "Every capture must be Omaha-scoped; a non-Omaha store identity fails the run"),

        S("compare_deals", "tool", ["gate_ad_window", "gate_omaha"],
          "grocery/compare-deals.ps1", {"date": date},
          "Union-window comparison across all seven stores; picks per-cell crowns"),

        S("resolve_graph", "model", ["compare_deals"], "graph/pipeline/resolve.py",
          {"allow_llm": True},
          "SHADOW: adjudicate candidate rows in the graph (does not price the live board)"),

        S("guards", "gate", ["compare_deals"], "grocery/guards.ps1", {},
          "The existing blocking guard suite (known-wrong, food-category, pack-basis, ...)"),

        S("publish_deals", "tool", ["guards"], "grocery/build-deals-page.ps1", {},
          "Render and publish the Omaha grocery prices page"),

        S("cost_recipes", "tool", ["guards"], "meal-prep/cost-recipes.ps1", {},
          "Re-cost every priceable recipe against the new board"),

        S("compute_v2", "tool", ["cost_recipes"], "meal-prep/compute-v2.ps1", {},
          "Per-serving macro + cost recompute"),

        S("top5_weekly", "tool", ["compute_v2"], "grocery/top5-weekly.ps1", {},
          "Weekly top-5 selection"),

        S("rotate_free_dinners", "tool", ["compute_v2"], "meal-prep/rotate-free-dinners.ps1", {},
          "Rotate the free-dinner window"),

        S("verify_board", "verify", ["publish_deals", "top5_weekly", "rotate_free_dinners"],
          "graph/eval/board_parity.py", {"mode": "shadow"},
          "SHADOW: compare the graph's matrix against the published board"),

        S("commit_push", "commit", ["verify_board"], "git", {},
          "Commit and push the day's data (the git-bus handoff to the Worker)"),
    ]
    return Plan(run_id=run_id, created_at=created_at,
                goal=f"daily grocery pipeline for {date}", steps=steps)


if __name__ == "__main__":
    import time
    from ids import run_id as mk
    stamp = time.strftime("%Y%m%dT%H%M%S")
    p = daily_pipeline_plan(mk("daily", stamp), time.strftime("%Y-%m-%dT%H:%M:%S"),
                            time.strftime("%Y-%m-%d"))
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "runs",
                       f"plan-{stamp}.json")
    print(p.save(os.path.abspath(out)))
    print(f"{len(p.steps)} steps, execution order:")
    for s in p.order():
        print(f"   {s.id:<22} {s.type:<7} <- {s.depends_on}")
