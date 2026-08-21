"""MUST-FIRE tests for the Python gates. A gate that has only ever passed proves nothing.

    sidecar/.venv/Scripts/python.exe graph/learning/test_gates.py

WHY THIS EXISTS. `test-guards.ps1` breaks each hard invariant inside a scratch copy of the
grocery tree and asserts `guards.ps1` fails with that guard's own text - so every PowerShell
guard is proved able to fail. Nothing did that for the newer Python gates, and the gap is not
theoretical: building `promote_aliases --gated` on 2026-08-21, the FIRST must-fire fixture
immediately found two bugs a passing run could never have shown -

  * on the "everything was withheld" exit it returned without recording holds, discarding two
    verdicts it had just spent two guard cycles earning;
  * its rollback restored commodities.json but not the board derived from it, so the NEXT run
    refused to start over aliases no longer present in any file.

Both were in the failure paths. Both were invisible to a run that succeeded.

Each test below states what it breaks and what it expects, and every one is paired with a CLEAN
TWIN - the same assertion against an unbroken input - because a test that fires on everything is
as useless as one that fires on nothing.

Read-only against the repo: fixtures are built in a temp directory and the real catalogue is
never written. Exit 0 all passed, 1 a test failed.
"""

from __future__ import annotations

import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

from graphdb import REPO_ROOT                                    # noqa: E402
import promote_aliases                                           # noqa: E402

CATALOG = os.path.join(REPO_ROOT, "grocery", "commodities.json")
PY = sys.executable
LINT = os.path.join(HERE, "lint_adjacency.py")

FAILS: list[str] = []
PASSES = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global PASSES
    if ok:
        PASSES += 1
        print(f"  ok    {name}")
    else:
        FAILS.append(f"{name}: {detail}")
        print(f"  FAIL  {name}   {detail}")


# ---------------------------------------------------------------- lint_adjacency
def test_lint(tmp: str) -> None:
    """Reopen the hole the milk fix closed; the lint must find it, and must be quiet once closed.

    milk excluded `chocolate\\s+milk` and still claimed "Our Family Milk, Lowfat, 1% Milkfat,
    Chocolate 1 Gal" - four tokens apart. That shipped a wrong price. If the lint cannot see that
    exact hole reopened, it cannot see the next one.
    """
    print("\nlint_adjacency")
    with open(CATALOG, encoding="utf-8-sig") as fh:
        catalog = json.load(fh)

    holed = copy.deepcopy(catalog)
    removed = False
    for row in holed:
        if row.get("id") == "milk":
            before = list(row.get("exclude") or [])
            row["exclude"] = [p for p in before if p != r"\bchocolate\b"]
            removed = len(row["exclude"]) != len(before)
    if not removed:
        check("fixture is valid", False, r"milk no longer carries \bchocolate\b - update this test")
        return

    holed_path = os.path.join(tmp, "commodities-holed.json")
    with open(holed_path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(holed, fh, indent=2, ensure_ascii=False)

    def run(path: str) -> str:
        p = subprocess.run([PY, LINT, "--commodity", "milk", "--catalog", path],
                           capture_output=True, text=True, errors="replace", cwd=REPO_ROOT)
        return p.stdout or ""

    fired = run(holed_path)
    n_fired = int(fired.split(" near-miss")[0].strip().split("\n")[-1] or 0) if "near-miss" in fired else -1
    check("MUST-FIRE: reopening milk's chocolate hole is detected", n_fired > 0,
          f"expected >0 near-misses, got {n_fired}")
    check("MUST-FIRE: it names the chocolate exclude", "chocolate" in fired,
          "the finding does not mention the pattern it is about")

    clean = run(CATALOG)
    n_clean = int(clean.split(" near-miss")[0].strip().split("\n")[-1] or 0) if "near-miss" in clean else -1
    check("CLEAN-TWIN: the shipped catalogue is quiet on milk", n_clean == 0,
          f"expected 0 near-misses on the real catalogue, got {n_clean}")


# ---------------------------------------------------------------- promote_aliases.blame
def test_blame() -> None:
    """blame() decides which commodity a guard failure accuses, and therefore what gets withheld.

    Under-blaming leaves the tree red; over-blaming costs one held alias. It must read a real
    guard line, and it must stay silent on a line that names nothing it promoted to.
    """
    print("\npromote_aliases.blame")
    real = ("  HARD FAIL: 1.59x factor  balsamic-vinegar / Family Fare  board=0.2465 link=0.3914  "
            "[Alessi Balsamic Vinegar 12.75 Oz]")
    cand = {"balsamic-vinegar": ["x"], "sweet-corn": ["y"]}
    check("MUST-FIRE: a real HARD FAIL line accuses its commodity",
          promote_aliases.blame(real, cand) == {"balsamic-vinegar"},
          f"got {promote_aliases.blame(real, cand)}")

    other = "  HARD FAIL: 2.0x factor  something-else / Aldi  board=1 link=2  [Thing]"
    check("CLEAN-TWIN: a failure naming nothing we promoted accuses nobody",
          promote_aliases.blame(other, cand) == set(),
          f"got {promote_aliases.blame(other, cand)}")

    warn = "  warn  balsamic-vinegar looks odd but this is only a warning"
    check("CLEAN-TWIN: a WARNING is not a failure and accuses nobody",
          promote_aliases.blame(warn, cand) == set(),
          f"got {promote_aliases.blame(warn, cand)}")


# ---------------------------------------------------------------- promote_aliases.promote_into
def test_promote_into() -> None:
    """A held pattern must never be re-promoted, and a withheld commodity must be skipped whole."""
    print("\npromote_aliases.promote_into")
    catalog = [{"id": "widget", "include": [r"\bwidget\b"], "exclude": []}]
    learned = {"widget": [r"\bgadget\b"]}

    added, refused, seen = promote_aliases.promote_into(copy.deepcopy(catalog), learned, {}, set())
    check("CLEAN-TWIN: an unheld, compiling pattern promotes", added.get("widget") == [r"\bgadget\b"],
          f"got {dict(added)}")

    held = {("widget", r"\bgadget\b"): "held for a measured reason"}
    added2, refused2, _ = promote_aliases.promote_into(copy.deepcopy(catalog), learned, held, set())
    check("MUST-FIRE: a HELD pattern is refused", not added2 and len(refused2) == 1,
          f"added={dict(added2)} refused={refused2}")
    check("MUST-FIRE: the refusal carries the recorded reason",
          refused2 and "measured reason" in refused2[0][2], f"got {refused2}")

    added3, refused3, _ = promote_aliases.promote_into(copy.deepcopy(catalog), learned, {}, {"widget"})
    check("MUST-FIRE: a withheld commodity promotes nothing", not added3, f"got {dict(added3)}")

    bad = {"widget": ["(unclosed"]}
    added4, refused4, _ = promote_aliases.promote_into(copy.deepcopy(catalog), bad, {}, set())
    check("MUST-FIRE: a pattern that will not compile is refused",
          not added4 and refused4 and "compile" in refused4[0][2], f"got {refused4}")

    ctrl = {"widget": ["bad\x08pattern"]}
    added5, refused5, _ = promote_aliases.promote_into(copy.deepcopy(catalog), ctrl, {}, set())
    check("MUST-FIRE: a control character (a \\b eaten in transit) is refused",
          not added5 and refused5 and "control character" in refused5[0][2], f"got {refused5}")


def main() -> int:
    print("must-fire tests for the Python gates\n" + "=" * 52)
    tmp = tempfile.mkdtemp(prefix="tc-gates-")
    try:
        test_lint(tmp)
        test_blame()
        test_promote_into()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("\n" + "=" * 52)
    if FAILS:
        print(f"FAILED {len(FAILS)} of {len(FAILS) + PASSES}")
        for f in FAILS:
            print("   " + f)
        return 1
    print(f"all {PASSES} assertions hold - every gate above was shown to FAIL when it should")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
