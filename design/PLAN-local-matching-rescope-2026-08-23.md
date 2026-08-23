# RE-SCOPE — PLAN-local-matching, phases 4 onward

**Status: PROPOSED, awaiting Brad's direction. Written 2026-08-23 after phase 3 and the
night's measurements. It does not replace `PLAN-local-matching-2026-08-22.md`; it
amends the phases that document has not yet reached, and says which of its assumptions
are now measured false.** Every number below is from
`graph/prompts/model-selection.md` addenda five through eight, or from the live graph.

---

## 1. The plan was aimed at the wrong failure

Its animating worry, stated in §1 and §4 and §6, is the model's **false rejects** — the
"~35 missing cells" hiding in rejections nobody reviewed. Phase 3 measured it:

| | |
|---|---|
| unreviewed model rejections | 3,315 |
| reviewed at random, blinded | 117 |
| **wrong** | **0** (95% CI 0.0% – 3.2%) |
| implied across the pile | 0, upper bound ~105 |

**There is no pile of missing cells.** §4's audit row closes with a number.

Meanwhile, here is where the lane's cost actually sits, on the same night:

    435 contested questions ->  96 rejected  |  316 llm_match_unverified  |  23 escalated
                                              \___________ 339 of 435 (78%) ___________/
                                                        became work for a human

    escalation-queue.json today: 368 rows - 326 confirm_match, 42 contested.
    The model's measured false-MATCH rate on this slice: 37%.

The model is nearly perfect at saying **no** and unreliable at saying **yes**, and it
says "maybe yes" 73% of the time. Every one of those becomes a Claude ruling. **The
plan's remaining phases should be re-pointed from the reject side to the match side**,
because that is where both the risk and the tokens are.

## 2. What is measured false, and what it costs the plan

**a. A high helper score is not evidence of a match.** Where the trained cross-encoder
was *most* confident the local model had blundered — 72 rows scored above 0.9 — the
local model was right **68 of 69**. This kills two rows of §4's table outright and
undermines §8.

**b. A single training run cannot separate two fine-tunes.** Four seeds per arm, corpus
and recipe fixed: holdout AUC ranged 0.9641–0.9674 and the live filter yield 8–20 of 435
*within* each arm. A promotion made on one run had to be reverted the same night. Any
gate that compares two candidates — §6's retrain cadence, §10's fine-tune — needs ≥3
seeds and a gap wider than the within-arm spread.

**c. §2 step 2's second safeguard does not exist.** "Very low score AND no partial
include hit" — the contested set *is* the no-include-hit rows, so the second condition is
true of every candidate by construction.

**d. The filter's headline was one draw.** "Removes 21 of 435" is really 8–20 depending
on the training shuffle, against 9 for the stock model.

## 3. Phase by phase, as it should now stand

### §3.3 adversarial second pass — PROMOTED to the front of phase 4
Re-ask every local MATCH with the instruction to argue NO_MATCH. This was third in a
list of three; it is now the single highest-value local change, because it attacks the
37% false-match rate and the 326-lead queue at once. The plan's own pre-registered test
stands and should be honoured: run it on the 375 `llm_confirmed` and the known false
matches, and **if survival does not separate them, drop it** rather than shipping it.

### §5 the pre-drafted packet — PROMOTED to the highest-value phase overall
326 leads are waiting. Every token saved per ruling multiplies by 326 and by every night
after. This is now the plan's main lever on its own stated goal, ahead of everything in
§3. One amendment: **do not order the packet by helper score.** Ordering "easiest first"
by a signal that is 68-of-69 wrong at the confident end would put the most misleading
rows on top.

### §3.2 memory by meaning — KEEP, unchanged priority
The bench bounds its value: priors move cold-start 0.79 → 0.83, so §3.2 must beat 0.83
to be worth its complexity. That bound is unaffected by tonight. Its target should now
be MATCH decisions rather than rejections.

### §3.4 thinking on the contested slice — KEEP, retargeted
Apply it to the MATCH and UNSURE cases, not the reject side. There is nothing left to win
on rejections.

### §4 the routing table — REWRITE
Three of its four rows rest on the helper carrying information it does not have.

| helper | LLM | plan said | should now be |
|---|---|---|---|
| NO | NO | consensus | **unchanged.** Safe, and it can finally populate `authority.py`'s consensus tier. |
| YES | YES | strong lead, §8 candidate | **re-derive without the helper.** The lead is LLM MATCH + survived §3.3 + no known-wrong neighbour. Helper agreement adds nothing. |
| YES | NO | the false-reject audit set | **retire.** Measured: 1 error in 69. The audit is done. |
| unclear | unclear | Claude packet | unchanged. |

### §7 loop hygiene — SPLIT
Keep the 16 promotion-holds and 5 `held_for_human`; each is a real decision. **Demote the
re-ask** (§2 step 8): re-adjudicating model-only rejections when a commodity gains an
adjudicated ruling was designed to recover missing cells, and there are ~0 to recover.

### §8 auto-confirm — PREMISE BROKEN, RE-DERIVE BEFORE BUILDING
Shadow mode was to watch the "helper + LLM agree on a match" tier. That tier is not
evidence. If §8 proceeds it must watch a differently-defined tier — LLM MATCH that
survived §3.3, with no known-wrong semantic neighbour — and the proof standard does not
move: **100% agreement with Claude over ≥200 rows, or it stays a lead forever.** A wrong
published price is still the failure this board exists to prevent.

### §10 the 27B fine-tune — TARGET CHANGES
Do not train it to reject better; it is already ~100% correct there. If it is trained at
all, the target is its MATCH behaviour, and its acceptance gate inherits the ≥3-seed rule
from (2b).

## 4. What the helper is actually for

Honest accounting of one night: of 21 questions it filtered, 19 the local model would
have rejected anyway. Its **entire unique effect** is the 2 escalations it suppressed —
and those are cases the model declined to rule on, which is the one thing in the lane
with no evidence either way.

So its defensible roles are narrow:

- **A cheap low-end pre-filter.** Safe (0 disagreements measured), free on a warm cache,
  and genuine insurance for scale: at ~1.3 s per model call, a recipe import pushing
  contested from 435 into the thousands would turn the nightly resolve into hours.
- **Nothing on the positive side.** Not a match signal, not an auditor of the local
  model, not a packet-ordering key.

**One change is worth making regardless of the rest of this document:** the filter should
not overrule an `escalated` verdict. An escalation is the model saying *I am not sure*,
and suppressing it is the helper's only unevidenced act. Rejecting where the model would
also reject costs nothing and risks nothing; overruling its uncertainty does both.

## 5. Newly open

- **A human spot-check of a dozen audit rows.** The reviewer that graded the local model
  is itself a language model; a shared blind spot would look exactly like agreement. This
  is the cheapest outstanding item in the plan and it underwrites §1's whole result.
- **Whether the 37% false-MATCH rate moves at all** under §3.3. If it does not, the lane's
  cost is structural and §5's packet is the only remaining lever.
- **The filter's yield is unstable** (8–20 by shuffle). A cut calibrated per candidate to
  a target false-reject rate would not swing like that; a fixed 1e-4 across models will.

## 6. Sequencing, amended

| phase | what | why it moved |
|---|---|---|
| 4 | **§5 packet** | 326 leads waiting; the plan's own goal, most directly |
| 5 | **§3.3 adversarial pass** | attacks the 37% false-match rate, the measured risk |
| 6 | §3.2 memory, §3.4 thinking | unchanged in value, retargeted at matches |
| 7 | §7 holds and `held_for_human` | real decisions; the re-ask is demoted out |
| 8 | §8 shadow mode | only after its tier is re-derived |
| 9 | §10 | optional, target changed, ≥3-seed gate |

Phases 1–3 held. What changes here is not the machinery they built but what the next
phases should point it at.
