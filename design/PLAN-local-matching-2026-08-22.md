# PLAN — Local-first matching: fewer Claude rulings, fewer mistakes, one question at a time

**Status: PROPOSED, awaiting Brad's direction. This document is the spec — build
from it, not from memory of it.**

> **AMENDED 2026-08-23 for phases 4 onward — see
> `design/PLAN-local-matching-rescope-2026-08-23.md`.** Phase 3 measured that the false
> rejects this plan is built around are ~0 (117 reviewed at random, 0 wrong), that a high
> helper score is not evidence of a match (68 of 69 wrong where it was most confident),
> and that a single training run cannot separate two fine-tunes. §4's routing table, §8's
> auto-confirm premise and §12's ordering are amended there. §§1–3 and phases 1–3 stand.

Written 2026-08-22 after a cold review of the
matching lane against the live graph. Scope is the **commodity matching system
only** — the recipe hunter is explicitly out of scope (§11).

Goal, in Brad's words: the smartest local system possible, so Claude usage is
saved for actual coding work. Restated operationally: **Claude tokens per
board-grade decision**, driven down by three levers in order of leverage —
answer without a model, answer locally and verify mechanically, and hand Claude
a pre-drafted packet rather than a blank question.

Companion: `design/MEASURE-local-finetune-feasibility-2026-08-22.md` (training
the 27B is possible here but slow; it is §10, last, optional).

---

## 1. The lane as it stands — measured 2026-08-22

Layer-5 outcomes in `question_verdicts`:

| status | n | share |
|---|---|---|
| `llm_rejected` | 3,692 | 89% |
| `llm_confirmed` (Claude ruled MATCH) | 375 | 9% |
| `known_wrong` | 65 | 2% |
| escalated / unverified | 9 | — |

Only **1,145** of the 3,692 rejections are the model's own (reason starts `llm`);
the rest are adjudicated rejections imported into the same status. Graph holds
687 Commodity nodes; 482 have a verdict; of the 205 never judged, **158 have
products** (settled entirely by the deterministic layers) and 47 have none.
Queue: 22 `confirm_match` + 28 `contested`. Learning loop: 183 proposals, 159
applied, **16 in promotion-holds** (passed shadow gate, failed live guard),
5 `held_for_human`. `decision_log` records 1,342 decisions under
`resolve-v4-reject-only-with-priors` and 378 under `review-v1`.

Four findings from the cold review that reshape the plan:

1. **The loop feeds the model its own unreviewed rejections as authority.**
   `_verdict_index` (resolve.py:219) pulls `llm_rejected` regardless of
   `decided_by`. A wrong model rejection becomes precedent for rejecting its
   neighbours. Nothing reviews it. This is the most important single fix (§3.1).
2. **The semantic sidecar and the resolver have never been introduced.**
   `sidecar/lib_match.py` answers the identical question — *is this product an
   instance of this commodity?* — with a bi-encoder + cross-encoder calibrated
   per commodity on ~2,816 accepted pairs, at AUC 0.985 and 100% recall on the
   24 known identity defects. It runs at 07:00 as a night auditor over the whole
   catalogue. `resolve.py` contains no reference to it. Two judges, same
   question, never compare notes.
3. **The bench flatters the model.** 93.5% of gold cases carry retrieved priors
   that hand the model its answer. The true cold-start rate is unmeasured.
4. **Exposure is smaller than first stated.** False-reject exposure is ~1,145 ×
   1/34 ≈ **~35 missing cells**, not ~100; and there is no cold backlog — the
   never-judged commodities were mostly settled by rules.

## 2. The target flow — the journey of one question

```
07:00  sweep (sidecar loaded)                         -> findings, as today
         + score every contested (commodity, product) pair   [NEW, cached]
         + embed every new product name                      [NEW, cached]
       sidecar exits
       llama-server starts                                    [NEW: scheduled]
         resolve over the contested set
         Learning Stage 1
       llama-server exits  (before any Claude session; never past the sweep)
```

| step | layer | change |
|---|---|---|
| 1 | deterministic rules | unchanged; grow faster via §7 |
| 2 | **helper first** (trained cross-encoder, cached scores) | **NEW.** Very low score AND no partial include hit -> `helper_rejected`, tentative, never reaches the LLM. Else pass on. |
| 3 | local LLM | four upgrades (§3). Does NOT see the helper score — independence is the point. |
| 4 | **combine** | **NEW** routing table (§4) |
| 5 | Claude packet | pre-drafted (§5) |
| 6 | after a ruling | gold + alias proposals (today) + **helper training data** (NEW) |
| 7 | learning loop | clear the 21 stuck; Stage-2 shadow gate unchanged |
| 8 | **re-ask** | **NEW.** Model-only rejections are re-adjudicated when their commodity gains adjudicated rulings. |
| 9 | auto-confirm | **shadow mode only** until proven (§8) |
| 10 | night auditor | keeps sweeping shipped cells, including Claude's confirms |

## 3. The local model, upgraded without touching its weights

### 3.1 Authority tiers in its memory (the loop fix)
`question_verdicts.decided_by` already exists. Three tiers:
- **adjudicated** (human, Claude `review-v1`, known-wrong) — shown as precedent
- **model consensus** (helper + LLM agree) — shown, labelled tentative
- **single-model** — never shown as precedent

### 3.2 Memory by meaning, across commodities
Replace `_prior_rulings`' bag-of-words overlap (`[a-z]{3,}` Jaccard, per
commodity) with nearest-neighbour over cached bge-m3 vectors, **across all
commodities**. Fixes cross-commodity transfer and the zero-word-overlap case
(coconut-oil / Epsom salt). Vectors are produced during the sweep
(`score_cache` already memoises by exact text) and searched from RAM at
resolve time — the sidecar and llama-server still never share the card.

### 3.3 Adversarial second pass
Every local MATCH is re-asked with the instruction to argue NO_MATCH. **Test
before wiring:** run on the 375 `llm_confirmed` and the known false matches; if
survival does not separate them, drop it.

### 3.4 Thinking on the contested slice only
`enable_thinking=False` is global (llm.py) for a budget reason from Phase 0.
Enable it only for UNSURE / below-threshold cases, with a larger `max_tokens`
and the grammar applied to the final answer. Measure on the bench before
adopting. 28 of the 50 queued items are this slice.

## 4. Combining the two votes

| helper | LLM | route |
|---|---|---|
| NO | NO | `llm_rejected`, decided_by = consensus |
| YES | YES, survived §3.3, no known-wrong semantic neighbour | **strong lead** -> top of Claude's packet; §8 candidate |
| disagree | | Claude packet, flagged, both opinions shown |
| YES | NO | also the **false-reject audit set** — where the ~35 cells live |
| unclear | unclear after §3.4 | Claude packet |

The helper never prices a cell. The LLM never prices a cell. Only `llm_confirmed`
from the review lane does, exactly as today (`v_current_cell`).

## 5. Claude's packet, pre-drafted

`review_escalations.py --emit-packet` already carries include/exclude patterns,
sibling include hits and known-wrong names. Add: the verdict and evidence at
the top, both scores, the deciding words highlighted, the three nearest
adjudicated rulings by meaning (§3.2), and ordering (easiest first). Batch size
is itself a lever — measure how many one session clears.

## 6. Training the helper — the weights that fit

`BAAI/bge-reranker-v2-m3` (~568M) fine-tuned as a **separate copy for the
resolve lane**. The sweep's model stays pinned (sidecar rule 3: a swap changes
every score in the estate). Minutes on this card under
`tools/local-llm/finetune-probe/gpu_watchdog.sh`.

- positives: gold MATCH (1,089) + the ~2,816 accepted pairs
- hard negatives: gold NO_MATCH (564), known-wrong (186), adjudicated rejections
- **holdout by commodity family**, so the test is cold by construction
- gates: beats stock on holdout AUC; still 100% recall on the 24 known defects;
  re-run `sidecar/backtest.py` against the new copy
- cadence: retrain monthly on everything Claude has ruled since

The model-only rejections (1,145) are not in any training set, so the helper's
verdict on them is genuinely out-of-sample — which is what makes §4's audit row
honest.

## 7. Loop hygiene

- Resolve the 16 promotion-holds and 5 `held_for_human`. Each is a decision,
  not a free win — the holds failed the *live* guard for cause.
- §2 step 8, re-ask: when a commodity gains an adjudicated ruling, re-queue its
  single-model rejections for one more local pass.

## 8. Auto-confirm, earned by proof

The strong-lead tier runs in **shadow mode**: predicts, writes nothing, is
compared against Claude's actual verdict on every row it touched. Promote to
skip Claude only at **100% agreement over >= 200 rows**. Below that it stays a
lead forever. A wrong published price is the failure this board exists to
prevent (blueberries 2026-07-14, coconut-oil crown 2026-07-28); nothing in this
plan relaxes that.

## 9. Measurement — the part that makes the rest real

- **Honest baseline first.** Run `graph/bench/bench.py` with priors ablated.
  That number, not 0.900, is what every change is measured against.
- **Standing weekly scorecard:** questions asked; settled by rules / helper /
  LLM consensus; sent to Claude; confirmed / rejected / deferred; tokens per
  Claude ruling (extend the `lane-tokens.ps1` attribution to this lane).
- Every phase ships with its before/after on the scorecard or it did not ship.

## 10. The 27B fine-tune — optional, last

Measured possible on this box (57.3 tok/s, 8.3 h/epoch, 0.33 GiB headroom) and
cheap in the cloud (~$10, ~1 h). It is last because §3 and §6 buy most of what
it would buy with no maintenance tail, and because the corpus and holdout it
needs are produced by the phases before it. Kill it if it does not beat stock +
§3.2 on the cold holdout.

## 11. Explicitly out of scope

- The recipe hunter (its own plan: `PLAN-token-efficiency-2026-08-16.md`).
- Browser-store capture. A large share of Claude's non-coding spend is the five
  stores without an API; no local model replaces that.
- Any change to what may price a cell, other than §8 under its proof standard.

## 12. Sequencing

| phase | what | effort | Claude cost to run |
|---|---|---|---|
| 1 | §9 baseline, §3.1 authority tiers, scorecard | 1–2 days | none |
| 2 | §2 nightly sequencing; helper scores + vectors cached in the sweep | 1–2 days | none |
| 3 | §6 train helper; §2 step 2 filter; §4 audit set | 2–3 days | a review session for the audit set |
| 4 | §3.2 memory, §3.3 self-argument, §3.4 thinking | 2–3 days | none |
| 5 | §5 packet | 1–2 days | none |
| 6 | §7 backlog, re-ask, retrain cadence | 1 day | ~21 rulings |
| 7 | §8 shadow mode | weeks of waiting | none |
| 8 | §10 | optional | none |

Phases 1–3 carry most of the value. Running the system costs no Claude;
building it costs Claude sessions, which is the budget line to watch — keep
each phase to its own fresh session.

## 13. Done means

- The 07:00 pipeline runs sweep -> resolve -> exit without a BLIND day.
- `_prior_rulings` cites only adjudicated rulings as precedent, by meaning,
  across commodities.
- The helper scores every contested pair before the LLM sees it, and the
  disagreement set is reviewed.
- Claude receives pre-drafted packets and the weekly scorecard shows tokens per
  ruling falling.
- Shadow mode has a number. Whether it promotes is that number's call, not ours.
