# OPEN ITEMS: Recipe Hunter, everything outstanding as of 2026-08-24

THE running list. Brad asked (during the 6b run) whether one was being kept; it was not - the cost
analysis lived in `WORKLIST-token-cost-2026-08-24.md` and several later findings lived only in the
session thread. This file is now the single ledger, and it links out rather than duplicating.

**Nothing here is built unless its status says DONE.** Per the 6b rules, C2/C4/C6-shaped work and
anything E-row-shaped is a proposal for Brad, never a follow-on build.

Status key: **DONE** landed and pushed | **OWED** promised same-day by the 6b criteria | **PROPOSAL**
needs Brad's order | **OPEN Q** a decision Brad owes before anything can be built.

---

## 1. Landed this session (DONE)

| # | item | commit |
|---|---|---|
| 1.1 | The macro band is a run parameter; `proteinMin` added to `in_band` across all three implementations, 5 new parity vectors, all neuter-proven | 2eba1d69 |
| 1.2 | `pop_dossiers` filters by the run's band (was deaf to it; 2 of first 10 pops qualified under the 6b band) | 2eba1d69 |
| 1.3 | `hunt-run.ps1 -Init` refuses to mint a run dir without a stated band; band written to run.json; daemon reads it back and CANNOT RUN without it | 2eba1d69 |
| 1.4 | Every `-Init` drill caller updated to pass a band (decide_apply, extract_sweep, hunt_daemon_drill, hunt_daemon_selftest x5) | 2eba1d69 |
| 1.5 | Plan corrected with a dated CORRECTED block inside the 6b criteria | 2eba1d69 |
| 1.6 | 6b run dir minted, deviations recorded BEFORE the run per section 10 | 70600d10 |
| 1.7 | Token-cost worklist written from measured data | 7163b3df |
| 1.8 | Qwen-offload analysis against the 1.4 doctrine | f0cdb541 |

---

## 2. OWED same-day (the 6b criteria require a fixture with a neuter proof for every new defect class)

### 2.1 An ingredient line that is a LIST OF ALTERNATIVES has no gram weight
Parked `one-pan-chicken-with-sweet-potatoes-kale-and-cranberries`:
> `'Prepared brown and wild rice blend, brown rice, quinoa, or cauliflower rice' has no gram weight`

The pipeline behaved correctly (never-a-silent-zero). What is missing is a DECISION about what should
happen to an alternatives line, plus a fixture freezing whichever answer Brad picks. See **OPEN Q 4.1**.

### 2.2 A GARNISH line with no quantity has no gram weight
Parked `cheese-stuffed-chicken-parmesan`:
> `'Fresh parsley (to garnish)' has no gram weight from the engine or from a ruling - a purchasable
> line with no weight cannot be costed`

Same refusal, DIFFERENT cause from 2.1: this line names one food but states no quantity at all. Needs
its own fixture. See **OPEN Q 4.2**.

### 2.3 The composite-rider PHANTOM false positive (a shared gate, red on a pattern it has never seen)
Wave 1's NO-GO blocker 1. `audit-spec-contradictions` PHANTOM went 0 -> 5; the batch auditor ruled all
five false positives and traced it in code:
> `spec-contradiction-lib.ps1, Get-PhantomFindings` builds `$own` from the scaler item/canon names and
> the display key BEFORE the colon only. Composite-rider foods named in the buy string AFTER the colon
> are invisible to it.

Pattern: `"1 3/4 teaspoons EACH dried basil and dried oregano (2 g)"` - basil is on the reader-facing
list and the shopper's list, and the gate cannot see it.

**The auditor already specified the repair AND its neuter proof:** extend `$own` to the full de-HTML'd
display line text and/or the scaler `buy` strings, **with a MUST-FIRE twin so a genuinely unbought food
still fires - the dr-pepper founding case must keep firing.** It also named what is not acceptable:
bumping the PHANTOM baseline to 5 without adjudication.

Owner: the gate's owning stage. NOT a mapper or capture issue - every named food resolves and is bought.

### 2.4 The alternate-cut mention (same blocker, second rule)
`"If you went with a heavier pork shoulder instead, give it closer to 10 hours"` on a recipe whose TITLE
offers both cuts. The auditor: needs either its own rule or a prose rephrase, and if the lib rule is
judged too risky the fallback owner is the WRITER stage (give each rider its own display line).

---

## 3. Found and NOT yet written down anywhere else

### 3.1 THE POP FILTER TRUSTS SOURCE NUMBERS; THE GATE USES OURS. THEY DISAGREE BY UP TO 15 g.
**This is a limitation of the work landed in 1.2 today, and it cost this run real money.**

| slug | pool (source page's claim) | ours (label-accurate, 14 servings) | protein delta |
|---|---|---|---|
| beef-back-ribs | 524 cal, 57 P, 32 C @ 4 svg | 585 cal, **41.6 P**, 31.2 C | **-15.4** |
| ina-garten-s-roast-chicken | 641 cal, 54 P, 8 C @ 8 svg | 667 cal, **46.3 P**, 13.4 C | **-7.7** |
| stuffed-chicken-breast | 559 cal, 61 P, 10 C @ 4 svg | 524 cal, 63.8 P, 9.6 C | +2.8 |

The pop admits candidates on the source's claim; the band gate retires them on our recompute. **2 of 9
accepted recipes (22%) died at the gate AFTER the mapper, the registrar and the pricer had been paid** -
the most expensive possible place to find out.

There is no cheap fix: the band gate needs the skeleton, which needs the map, so the band genuinely
cannot be ruled before the map is paid for. The levers are all pre-filter side and all imperfect:
- a margin at the pop (source protein >= floor + N%), which would also exclude honest candidates;
- calibrating that margin from measured (source, recomputed) pairs as they accumulate - this run just
  produced the first three;
- accepting the 22% as the price of a source-claim pre-filter, and recording the divergence so the
  calibration data builds up either way.

**Minimum action regardless of which lever Brad picks: RECORD the (source, recomputed) pair on every
band-gate ruling.** Without it the calibration data is thrown away every run.

### 3.2 The source pages' protein claims are not reliable - which is what the new floor is FOR
`beef-back-ribs` advertised 57 g protein and computes to 41.6 g. Before today there was no protein floor
anywhere in the estate, so it would have published into a "50 g protein or more" run at 41.6 g. Recorded
as the justification for 1.1, not as a defect.

### 3.3 The pool lane pops the whole qualifying backlog regardless of `--target`
It popped all 21 qualifying candidates for a target of 12, across three loops, before printing "no
available candidate left". That is the streaming design working as specified - it does not stop popping
until ACCEPTANCES reach the target - but it means the decider ruled on 21 dossiers to reach 9
acceptances. At 2,519 tokens per candidate the waste is small (~25k), so this is recorded rather than
proposed for change.

### 3.4 The JS half of the parity gate was NOT run this session
`hunt_lib.py --parity` is green 63/63 and `--selftest` verifies the hunt-lib.js hash stamp, so the
spliced copy is provably current. But `hunt-lib-parity.js` itself runs only inside a zero-agent Workflow
and there is no local node runtime, so the JS implementation of the new `proteinMin` clause has **not
been executed**. The Python side and the hash stamp are green; the JS side is unverified by execution.
Flagged rather than claimed.

### 3.5 Wave 1 closed on DRAIN at 2 recipes, not on count
Expected under the trimmed target and the narrow band, and correct behaviour (a wave closes on drain
when nothing upstream can still arrive). Recorded so the steady-state measurement is read honestly.

---

## 4. OPEN QUESTIONS for Brad (nothing can be fixtured until these are answered)

### 4.1 What should the pipeline do with an ALTERNATIVES ingredient line?
`"brown and wild rice blend, brown rice, quinoa, or cauliflower rice"`. Options: park the recipe (today's
behaviour); pick the first alternative and say so on the card; reject the recipe at extraction before
anything is paid for; or flag it at extraction so the mapper is never dispatched. The last is cheapest
and needs no model - it is an `or`-list check on an ingredient line.

### 4.2 What should the pipeline do with a GARNISH line that states no quantity?
`"Fresh parsley (to garnish)"`. Options: park (today); treat garnish lines as optional and drop them from
the cost and the macros with a note; or assign a conventional garnish weight, which invents a number and
would need its own justification.

### 4.3 Which cost items from the worklist, if any, are ordered?
See `WORKLIST-token-cost-2026-08-24.md`. Ranked by my read: **B first** (hand the registrar its evidence -
lowest risk, ~797k on this run, the daemon already holds the data), then **A** (seeding order so the
mapper never batches one, 500k-900k), then **F** (stamp round-trip and tool-call counts, or none of this
is verifiable later), then **C/D**.

### 4.4 Is the 6b target of 12 abandoned, or is a second run wanted?
The qualifying pool held 21 candidates and yielded 9 acceptances; the band is narrow against a pool
harvested under a wider one. Item **H** below would widen what is reachable without touching the band.

---

## 5. Carried from before this session (still open)

### 5.1 The ingest pre-filter can be NARROWER than a run band
`harvest.py` qualifies at hard-coded 400-650 cal / <= 35 carbs, so a run band admitting 36-40 g carbs
cannot reach those candidates. Measured: 3 stranded under the 6b band. Fix is a re-qualify pass over
numbers already stored on each candidate - no re-fetch needed. Recorded in the plan's 2026-08-24
correction block. Directly relevant to OPEN Q 4.4.

### 5.2 Cosmetic: `hunt-daemon.py:1115` SyntaxWarning
`invalid escape sequence '\m'` in a docstring, printed on every invocation. One-line fix. Deliberately
held back so the daemon's own source was not edited while it was executing.

---

## 6. In flight at the time of writing

Wave 1 is in its ONE repair cycle after the NO-GO. Two recipes still at `mapped` may yet reach a wave 2.
The full 6b report - the five numbers against target, every gate closure with its inspection, and the
PASS/NO verdict against the criteria block's own NO list - is owed when the daemon exits.
