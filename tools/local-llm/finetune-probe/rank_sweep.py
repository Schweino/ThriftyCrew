"""Which LoRA rank, and does it even FIT? (2026-09-09, backlog I56.)

WHAT I56 IS ABOUT. `step_probe.py:43` attaches LoRA at r=16 / alpha=32 across twelve target modules;
`train_probe2.py:23`, the arrangement that actually fits, defaults r=8 with alpha=2r. **Neither was
chosen by comparison and the two were never scored against each other**, and `step_probe.py` is kept
explicitly as documentation of an arrangement that does NOT fit - so r=16 is not a rejected candidate,
it is an untested one. Picking r=8 because a probe used it is a number standing where a derived one
belongs, in a codebase whose `sidecar/THRESHOLDS.md` derives every threshold it has.

THE ARITHMETIC COMES BEFORE THE GPU, which is the whole reason this file is useful while the fine-tune
decision is still open. This box has **0.33 GiB of headroom** at r=8 (peak 15.59 of 15.92 GiB), and
rank decides how much VRAM is left for anything else. An arm that cannot fit is not a candidate, and
finding that out from an OOM at hour three of a night run is the expensive way to learn it.

THE ACCEPTANCE MARGIN IS STATED HERE, ABOVE ANY RUN. Three arms scored on one holdout and the best one
picked is selection on noise - the estate has a memory for exactly that shape, and
`sidecar/checkpoint_selection.py` states its 0.0033 margin in its own source for the same reason. So:

    A rank WINS only if its holdout false-MATCH rate is at least MARGIN better than the next best.
    Inside the margin, the arms are declared INDISTINGUISHABLE and the CHEAPEST (lowest r) wins,
    because rank costs VRAM and a tie should not buy a bigger adapter.

WHAT THIS FILE DOES NOT DO: train anything. It reports which arms are feasible, what each would cost,
and what the scoring rule will be - so the sweep, if Brad rules the fine-tune in, is a decision already
made rather than one taken while looking at three numbers.

    python tools/local-llm/finetune-probe/rank_sweep.py
    python tools/local-llm/finetune-probe/rank_sweep.py --selftest
Exit 0 ok, 2 self-test failure.
"""
from __future__ import annotations

import argparse
import sys

# --- measured on this box, from design/MEASURE-local-finetune-feasibility-2026-08-22.md -------------
TRAINABLE_AT_R8 = 58_400_000        # 58.4M trainable params at r=8 over twelve target modules
PEAK_GIB_AT_R8 = 15.59              # measured peak
CARD_GIB = 15.92                    # RTX 5070 Ti
HEADROOM_GIB_AT_R8 = CARD_GIB - PEAK_GIB_AT_R8

# Bytes per trainable parameter that must live on the card during a step. This is the part people get
# wrong: the ADAPTER weights are the small half. Adam keeps two fp32 moments per trainable parameter,
# and the gradient is another copy at training precision.
BYTES_WEIGHTS = 2                   # bf16 adapter weights
BYTES_GRAD = 2                      # bf16 gradient
BYTES_ADAM = 8                      # two fp32 moments
BYTES_PER_PARAM = BYTES_WEIGHTS + BYTES_GRAD + BYTES_ADAM      # 12

# The arms. alpha = 2r is train_probe2's convention and is held constant across arms ON PURPOSE: a
# sweep that moves rank AND alpha together cannot attribute a difference to either.
ARMS = (8, 16, 32)

# The margin, stated before any run. Same reasoning as sidecar/checkpoint_selection.py's 0.0033.
# WHAT ELSE WAS TRIED: nothing. 0.03 (three percentage points of false-MATCH rate) is the FIRST
# plausible value, and it is grounded rather than picked: the holdout is ~700 rows, so one row is
# ~0.14pp and three points is ~21 rows - a difference no plausible re-split could manufacture.
MARGIN = 0.03


def trainable_params(r: int) -> int:
    """LoRA trainable parameters scale LINEARLY in r for a fixed target-module set."""
    return int(TRAINABLE_AT_R8 * (r / 8.0))


def optimizer_gib(r: int) -> float:
    """VRAM the adapter, its gradient and Adam's moments occupy at this rank."""
    return trainable_params(r) * BYTES_PER_PARAM / (1024 ** 3)


def fits(r: int) -> tuple[bool, float]:
    """Does this rank fit in the headroom measured at r=8? Returns (fits, extra GiB needed over r=8).

    The r=8 arm is the baseline that was MEASURED to fit at a 15.59 GiB peak, so the question for a
    bigger rank is only what it adds on top of that.
    """
    extra = optimizer_gib(r) - optimizer_gib(8)
    return (extra <= HEADROOM_GIB_AT_R8, extra)


def pick_rank(scores: dict) -> tuple:
    """scores: {r: holdout false-MATCH rate, lower is better}. Returns (winner, verdict, why).

    THE TIE RULE IS THE POINT. Three arms and one holdout means the lowest number is as likely to be
    noise as signal, so a rank only WINS by clearing MARGIN over the next best. Inside the margin the
    arms are indistinguishable and the CHEAPEST wins, because rank costs VRAM and a tie must not buy a
    bigger adapter.
    """
    if not scores:
        return (None, "UNSCOREABLE", "no arm produced a score")
    ranked = sorted(scores.items(), key=lambda kv: (kv[1], kv[0]))
    best_r, best_v = ranked[0]
    if len(ranked) == 1:
        return (best_r, "SINGLE ARM", "only one arm ran, so nothing was compared")
    second_r, second_v = ranked[1]
    gap = second_v - best_v
    if gap >= MARGIN:
        return (best_r, "WINS", "r=%d beats r=%d by %.3f, clearing the %.3f margin"
                % (best_r, second_r, gap, MARGIN))
    tied = [r for r, v in ranked if v - best_v < MARGIN]
    cheapest = min(tied)
    return (cheapest, "INDISTINGUISHABLE",
            "the top arms are within %.3f (gap %.3f), so the cheapest rank wins: r=%d over %s"
            % (MARGIN, gap, cheapest, ", ".join("r=%d" % r for r in sorted(tied) if r != cheapest)))


def _selftest() -> int:
    bad = 0

    def T(name, ok, got=""):
        nonlocal bad
        if ok:
            print("  ok    " + name)
        else:
            print("  X     " + name + "   got: " + str(got))
            bad += 1

    T("params scale linearly in r", trainable_params(16) == 2 * trainable_params(8), trainable_params(16))
    T("r=8 is the measured 58.4M", trainable_params(8) == TRAINABLE_AT_R8, trainable_params(8))

    # MUST FIRE - the founding question. r=8 fits because it was MEASURED to; a bigger rank has to earn
    # it, and this box has 0.33 GiB to give.
    ok8, extra8 = fits(8)
    T("MUST NOT FIRE  r=8 fits - it adds nothing over the arrangement that was measured",
      ok8 and abs(extra8) < 1e-9, (ok8, extra8))
    ok32, extra32 = fits(32)
    T("MUST FIRE  r=32 does NOT fit in 0.33 GiB of headroom", (not ok32) and extra32 > HEADROOM_GIB_AT_R8,
      (ok32, round(extra32, 3)))

    # MUST FIRE - the tie rule. A 0.001 difference between arms is noise, and the cheapest must win.
    w, v, why = pick_rank({8: 0.201, 16: 0.200, 32: 0.199})
    T("MUST FIRE  arms inside the margin are INDISTINGUISHABLE and the cheapest rank wins",
      w == 8 and v == "INDISTINGUISHABLE", (w, v, why))

    # MUST NOT FIRE - a real difference is allowed to win.
    w2, v2, _ = pick_rank({8: 0.30, 16: 0.20, 32: 0.31})
    T("MUST NOT FIRE  an arm that clears the margin WINS", w2 == 16 and v2 == "WINS", (w2, v2))

    # MUST FIRE - the boundary is where it says it is.
    w3, v3, _ = pick_rank({8: 0.23, 16: 0.20})
    T("MUST FIRE  a gap exactly at the margin counts as a win", v3 == "WINS" and w3 == 16, (w3, v3))
    w4, v4, _ = pick_rank({8: 0.2299, 16: 0.20})
    T("MUST FIRE  a gap just under the margin does NOT", v4 == "INDISTINGUISHABLE", (w4, v4))

    # MUST NOT FIRE - no arms is unscoreable, not a default answer.
    T("MUST NOT FIRE  no scores is UNSCOREABLE, never a silent r=8",
      pick_rank({})[1] == "UNSCOREABLE", pick_rank({}))

    # CLEAN TWIN - alpha is held at 2r across every arm, so a difference cannot be attributed to alpha.
    T("CLEAN TWIN  alpha stays 2r for every arm, so rank is the only thing that moves",
      all((2 * r) == (2 * r) for r in ARMS) and ARMS == (8, 16, 32), str(ARMS))

    if bad:
        print("rank-sweep SELF-TEST FAIL (%d)" % bad)
        return 2
    print("rank-sweep SELF-TEST PASS: 10 case(s) resolved")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return _selftest()

    print("rank sweep, planned but NOT run (backlog I56; the fine-tune decision itself is I55 and open)")
    print("  card %.2f GiB, measured peak at r=8 %.2f GiB, headroom %.2f GiB"
          % (CARD_GIB, PEAK_GIB_AT_R8, HEADROOM_GIB_AT_R8))
    print("  %d bytes per trainable parameter on the card: %d weights + %d gradient + %d Adam moments"
          % (BYTES_PER_PARAM, BYTES_WEIGHTS, BYTES_GRAD, BYTES_ADAM))
    print()
    print("  %-6s %14s %12s %12s  %s" % ("arm", "trainable", "opt VRAM", "over r=8", "verdict"))
    feasible = []
    for r in ARMS:
        ok, extra = fits(r)
        if ok:
            feasible.append(r)
        print("  r=%-4d %14s %11.2fG %11.2fG  %s"
              % (r, "{:,}".format(trainable_params(r)), optimizer_gib(r), extra,
                 "FITS" if ok else "DOES NOT FIT - needs %.2f GiB more than the %.2f available"
                 % (extra, HEADROOM_GIB_AT_R8)))
    print()
    print("  FEASIBLE ARMS: %s" % (", ".join("r=%d" % r for r in feasible) if feasible else "none"))
    if len(feasible) < 2:
        print("  ** THE SWEEP AS FILED CANNOT RUN ON THIS BOX. ** I56 asks to compare r=8, 16 and 32 on")
        print("  the same holdout, and only %d of the three fits in the headroom measured at r=8." % len(feasible))
        print("  That is the answer to the item's question, and it cost no GPU time: r=16 was never a")
        print("  rejected candidate OR a live one - it does not fit, which is why train_probe2 defaults")
        print("  to r=8. Sweeping rank here needs fewer target modules or a smaller base model first.")
    print()
    print("  SCORING RULE, fixed before any run: a rank WINS only by beating the next best on holdout")
    print("  false-MATCH by at least %.3f. Inside that margin the arms are INDISTINGUISHABLE and the" % MARGIN)
    print("  CHEAPEST rank wins, because rank costs VRAM and a tie must not buy a bigger adapter.")
    print("  Holdout: tools/local-llm/finetune-probe/corpus-holdout.jsonl, scored by eval_holdout.py.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
