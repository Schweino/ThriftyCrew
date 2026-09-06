r"""checkpoint_selection.py - which epoch's weights actually ship.

    python sidecar/checkpoint_selection.py --selftest

Split out of finetune_reranker.py so it can be tested WITHOUT torch. The training script imports
torch and transformers at module scope and runs on the sidecar venv; run-gates uses the pinned
interpreter, which has neither. A decision rule nobody can run in the gate is a decision rule
nobody checks, which is the hole this whole file exists to close (backlog E27).

THE DEFECT IT FIXES. finetune_reranker.py scored holdout AUC after every epoch, appended it to the
history its model card publishes, and then called save_pretrained OUTSIDE the loop - so the weights
that reached disk were whichever epoch ran last, and the per-epoch scores it had just measured
decided nothing. If epoch 2 peaked and epoch 4 had begun to overfit, epoch 4 shipped and the card
recorded the decline in the artefact we shipped.

WHY THE OBVIOUS FIX IS WRONG, AND THIS ONE IS NOT A PLAIN ARGMAX. "Keep the best epoch" selects the
maximum of k noisy draws, and the maximum of k draws is optimistic by construction even when every
draw comes from the same distribution (backlog E21). finetune_reranker.py's own docstring records
the size of that noise from a measurement taken 2026-08-23: four runs of the SAME recipe differing
only by seed produced holdout AUC from 0.9641 to 0.9674. So a 0.002 lead by epoch 2 over epoch 4 is
a shuffle, and restoring epoch 2 on the strength of it is selecting on noise while believing you
corrected for it.

The rule therefore keeps the LAST epoch by default and moves only when an earlier one leads by more
than a stated margin - the estate's own measured within-arm spread. That is E21's second fix applied
here: the acceptance threshold is written down, in the units of the metric, before the run.

A MARGIN OF 0 RESTORES PLAIN ARGMAX and is the right setting when the caller has some other reason
to trust small differences. It is not the default because nothing here has produced that reason.
"""
from __future__ import annotations

import argparse
import sys

# The within-arm holdout-AUC spread measured 2026-08-23 across four same-recipe seeds (0.9641-0.9674),
# recorded in finetune_reranker.py's docstring. A difference smaller than this is not evidence.
NOISE_MARGIN = 0.0033


def pick_shipping_epoch(history, margin=NOISE_MARGIN, key="holdout_auc"):
    """Return (epoch, reason). `history` is the training script's per-epoch record, in order.

    The reason string is returned rather than logged so the caller can put it in the model card:
    a card that states WHICH epoch shipped and why is the difference between an artefact you can
    audit later and one you have to retrain to understand.
    """
    rows = [h for h in (history or []) if h.get(key) is not None]
    if not rows:
        return None, "no epoch produced a score, so there is nothing to choose between"

    last = rows[-1]
    best = max(rows, key=lambda h: h[key])

    if best["epoch"] == last["epoch"]:
        return last["epoch"], "the last epoch was also the best scoring one"

    lift = best[key] - last[key]
    if lift > margin:
        return best["epoch"], (
            "epoch %d beat the last epoch by %.4f, which clears the %.4f margin"
            % (best["epoch"], lift, margin))
    return last["epoch"], (
        "epoch %d led by only %.4f, inside the %.4f margin this estate measured for same-recipe "
        "seed noise, so that lead is not evidence and the last epoch ships"
        % (best["epoch"], lift, margin))


def should_stop(history, patience, margin=NOISE_MARGIN, key="holdout_auc"):
    """True when `patience` epochs have passed without a NEW best. patience 0 disables it.

    Deliberately uses a plain best rather than a margin-beating best: stopping early is cheap and
    reversible - you rerun with more epochs - while shipping the wrong weights is neither. The
    margin guards the irreversible decision, not this one.
    """
    if not patience:
        return False
    rows = [h for h in (history or []) if h.get(key) is not None]
    if not rows:
        return False
    best = max(rows, key=lambda h: h[key])
    return (rows[-1]["epoch"] - best["epoch"]) >= patience


def overfit_gap(row, train_key="train_auc", holdout_key="holdout_auc"):
    """Train AUC minus holdout AUC for one epoch, or None when the train side was not scored.

    Backlog E28: the script reported holdout AUC against a stock baseline, which answers whether
    fine-tuning helped and NOT whether it memorised. Those need different fixes, so they need
    different numbers.
    """
    if not row or row.get(train_key) is None or row.get(holdout_key) is None:
        return None
    return row[train_key] - row[holdout_key]


def selftest():                                                                # noqa: C901
    fails = []

    def T(name, cond, got=""):
        if cond:
            print("  ok    %s" % name)
        else:
            print("  X     %s   got: %s" % (name, got))
            fails.append(name)

    def H(*pairs):
        return [{"epoch": e, "holdout_auc": v} for e, v in pairs]

    # THE FOUNDING BUG. Epoch 2 peaks, epoch 4 has overfit well past the noise floor, and the old
    # code shipped epoch 4 because save_pretrained sat outside the loop.
    ep, why = pick_shipping_epoch(H((1, 0.950), (2, 0.972), (3, 0.961), (4, 0.940)))
    T("MUST FIRE  a clear mid-run peak ships, not the last epoch", ep == 2, "%s (%s)" % (ep, why))

    # THE CLEAN TWIN. Same shape, but the lead is 0.002 - inside the seed noise this estate measured.
    # A plain argmax would ship epoch 2 here and call a shuffle a correction.
    ep, why = pick_shipping_epoch(H((1, 0.960), (2, 0.9670), (3, 0.9660), (4, 0.9650)))
    T("CLEAN TWIN  a lead INSIDE the measured noise margin does not move the checkpoint",
      ep == 4 and "not evidence" in why, "%s (%s)" % (ep, why))

    ep, why = pick_shipping_epoch(H((1, 0.940), (2, 0.955), (3, 0.971)))
    T("the last epoch ships when it is also the best", ep == 3, "%s (%s)" % (ep, why))

    ep, why = pick_shipping_epoch(H((1, 0.960), (2, 0.9670), (3, 0.9650)), margin=0.0)
    T("margin 0 restores plain argmax, as documented", ep == 2, "%s (%s)" % (ep, why))

    ep, why = pick_shipping_epoch([])
    T("an empty history returns no epoch rather than raising", ep is None, str(ep))

    ep, why = pick_shipping_epoch([{"epoch": 1}])
    T("an epoch that produced no score is not treated as a score of zero", ep is None, str(ep))

    # A single epoch is the common case at the default --epochs 2 minus one, and must not crash.
    ep, why = pick_shipping_epoch(H((1, 0.9)))
    T("a one-epoch run ships that epoch", ep == 1, "%s (%s)" % (ep, why))

    T("patience 0 never stops early", not should_stop(H((1, 0.97), (2, 0.95), (3, 0.94)), 0))
    T("MUST FIRE  patience 2 stops after two epochs with no new best",
      should_stop(H((1, 0.97), (2, 0.95), (3, 0.94)), 2))
    T("CLEAN TWIN patience 2 does NOT stop when the last epoch set a new best",
      not should_stop(H((1, 0.94), (2, 0.95), (3, 0.97)), 2))
    T("patience does not fire one epoch early",
      not should_stop(H((1, 0.97), (2, 0.95)), 2))

    g = overfit_gap({"train_auc": 0.995, "holdout_auc": 0.965})
    T("MUST FIRE  the overfit gap is train minus holdout", abs(g - 0.030) < 1e-9, str(g))
    T("a missing train score reports no gap rather than a gap of zero",
      overfit_gap({"holdout_auc": 0.965}) is None)

    if fails:
        print("SELF-TEST FAIL: %d case(s)" % len(fails))
        return 1
    print("SELF-TEST PASS: checkpoint selection, including the noise-margin twin that separates a "
          "real mid-run peak from a same-recipe shuffle")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
