# PLAN: the map lane finishes the judge contract - the split, ruled falsifiable-first

Date: 2026-08-25. Author: this session, reviewing an EXTERNAL architecture proposal Brad
commissioned against design\BRIEF-map-lane-architecture-2026-08-25.md. Status: WRITTEN FOR
RATIFICATION - nothing here is built, and unit U0 exists precisely so most of it may never need
to be. Brad's rulings required at section 8 before any unit after U0 starts.

## 0. The verdict on the external proposal, in one paragraph

The proposal is RIGHT in direction and WRONG in two particulars, and one of its numbers is
contradicted by evidence already in this estate. Right: it independently found the ratified
judge-contract shape ("the daemon gathers, the judge rules"), correctly named the mapper as the
last hold-out, kept every gate, and made itself falsifiable - that last property is why it is
worth building from rather than discarding. Wrong, first: it classifies the shopping ("buy")
string as "deterministic template + unit normalisation," and this estate's own recorded scar says
the opposite in as many words - "The `buy` string cannot be mechanised - '7 oz, room temperature
(an 8 oz brick minus 2 tbsp)' is a judgment about what a cook holds, and D8 LOCKS it into the
intake" (map-preresolve.ps1 header, with the measurement: 2 of 7 v2-corpus lines quantize away
from the exact scale). Wrong, second: it puts web retrieval inside map-preresolve.ps1, when the
estate's gather precedent is the daemon's python road (gather_price_evidence, fill_fdc_shelf) with
its rate-limit discipline. And the number: its success bar of 90-120 s for the split judge sits at
the optimistic edge of what the estate's own measurements already bracket - section 2's arithmetic
puts the judgment increment alone at roughly 250-290 s in the current shape, which is AT the
proposal's own failure line. That is not a reason to refuse the split; it is the reason U0 runs
before anything is built.

## 1. What the proposal got right, kept verbatim as the spec's skeleton

1. The split itself: mechanical gather -> one judge dispatch over OPEN WORK ONLY -> mechanical
   assemble. The same contract as the registrar (F2), QA (F3) and the auditor (CHANGE A).
2. Jobs 2 and 4 (residual identity rulings, new-commodity proposals) stay with the judge, on the
   ratified pin (Opus 5 / high - Brad, 2026-08-25).
3. The full recipe context still travels to the judge, so situational awareness is preserved -
   what is removed is the OBLIGATION to emit bulk, never the sight of it.
4. Falsifiable success/failure criteria, reported with numbers either way.
5. Every gate, the never-assert-identity rule, QA independence, the single-writer rule: untouched.

## 2. The arithmetic the proposal did not have, and this estate does

The proposal infers that isolating the 11 identity decisions will collapse the 469 s dispatch.
The estate already holds a partial control for that inference:

- m1 batch A (2026-08-25): the SAME mapper over 3 recipes with effectively ZERO residual
  adjudication (two slugs fully pre-resolved, one pantry residual) - **221 s**. That is the
  bulk-dominant workload almost alone: buy strings for ~30 lines, 2 label acquisitions, payload
  emission.
- T-shakedown (2026-08-25): bulk + 11 residual adjudications - **469 s**.
- m1 batch B: bulk + 15-16 residuals - **512 s**.

So the judgment increment in the CURRENT shape is roughly 469-221 = **248 s** (11 residuals) to
512-221 = **291 s** (15-16), i.e. ~20-25 s per residual line. A judgment-only dispatch would also
run on a much smaller context (~10k chars instead of 28.6k) with zero retrieval turns, which
should reduce that - by how much is exactly what nobody knows and exactly what U0 measures. But
the honest prior is: **the split judge plausibly lands at 2-4 minutes, not 90-120 s**, and the
proposal's failure criterion (">3-4 min means the hypothesis is falsified") may fire.

The end-to-end arithmetic, stated so the target is honest: even with the map at 2 min, the
measured tail (write ~2 min at width, QA ~0.5, preaudit ~0.3, wave audit ~2.9, publish) puts a
3-recipe no-new-pricing chain at roughly **8-9 min**. The 6-7 min target therefore needs the map
split AND movement in the wave audit, or Brad's acceptance of ~8-9. That is a conversation, not a
softening: the audit's 2.9 min / 11 turns is one turn over its own target and has its own
decomposition owing.

**CORRECTED in the same commit, and it is this plan's author's own error:** the brief handed to
the external reviewer said prior optimisation rounds "did not move its wall clock." Overstated.
M1-M4 moved the like-for-like batch from 368 s to 221 s (40%). What has not moved is the ~8 min
figure for RESIDUAL-HEAVY batches, which is the case that matters. The brief carries the same
correction.

## 3. U0 - the falsification probe, run BEFORE anything is built

The T-shakedown's artifacts are on disk and in git: the pre-resolve tables, the mapper's actual
rulings, the residual lines. U0 hand-assembles the judgment-only prompt the split WOULD produce -
full recipe context, the 11 residual lines, their FDC-shelf evidence, the new-bid list, label
evidence gathered manually for the few no-DB terms - and dispatches the mapper agent ONCE on its
existing pin. One dispatch, ~60-120k raw, zero code changes.

- Judge-only wall <= ~120 s: the proposal's optimistic bar is real; build U1-U4.
- 2-4 min: the split buys roughly half the map lane; E2E lands ~8-9 min; Brad decides whether
  that is worth the build before U1 starts.
- \>= 4 min: the inference is FALSIFIED - the expensive reasoning is inherent to the identity
  decisions - and the 6-7 min target is unreachable without relaxing a ratified constraint. That
  result is reported with its numbers and the rest of this plan is NOT built.

U0's cost of being wrong: a single-dispatch probe is not a perfect twin of the built shape (no
schema re-ask pressure, hand-built evidence packs). It can mislead by tens of seconds, not by the
minutes the decision needs.

### 3.1 U0 RAN 2026-08-25. The result, and it is not the one anybody hoped for.

Dispatched the real `recipe-ingredient-mapper` on its ratified pin against a hand-built
judgment-only prompt (17,228 chars vs the monolith's 28,586), carrying the full recipe for all three
slugs, the 11 residual lines, their gathered evidence, and no obligation to emit buy strings, gram
weights or anything already settled.

| | monolithic (T-shakedown) | U0 judgment-only | change |
|---|---|---|---|
| wall | **469 s** | **317 s** | **-32%** |
| raw tokens | 349,292 | 64,343 | **-82%** |
| tool calls | 13 | 18 | +5 |
| prompt | 28,586 ch | 17,228 ch | -40% |

**Against the external proposal's success bar of 90-120 s: FALSIFIED.** Against this plan's own
falsification line (>= 4 min): 317 s crosses it. Two findings follow, and the second is the
important one.

**1. Wall clock here is not driven by token volume, and now we know.** Tokens fell 82% while wall
fell 32%. That asymmetry retroactively explains why two prior rounds of token optimisation moved
cost and not minutes: what costs the wall is reasoning time plus SERIAL tool round trips, neither of
which shrinks when you hand the judge less to write. Any future proposal reasoned from token counts
should be read against this line.

**2. THE SHELF SERVED A WRONG ROW ON A MAIN PROTEIN, AND ONLY THE JUDGE'S DISTRUST CAUGHT IT.** The
FDC shelf offered `fdc:172952 Sausage, Italian, sweet, links` at 149 cal/100 g for the line "5
Italian Sausage links, about 1.5-2 pounds" - a raw purchase weight, and the main protein of that
dish. The judge rejected it, went and found `fdc:171631 Sausage, Italian, pork, mild, raw` at 290
cal, and stated the consequence: taking the shelf row understates that recipe by roughly 33% (~656
cal/serving becoming ~440). It made 18 tool calls, MORE than the monolith's 13, precisely because it
distrusted gathered evidence and was right to.

That is a measured counterexample to the external proposal's classification of Job 3 ("web retrieval
+ transcription - does NOT need expensive judgment; the tool calls are cheap and transcription is
extraction, not identity judgment"). On this batch, choosing WHICH gathered row is the food was
exactly identity judgment, on the number that decides whether a recipe is honest. A pre-pass that
gathers and a judge that trusts the gather would have shipped the error.

**What U0 therefore rules.** The split is worth roughly 150 s of a 469 s dispatch - real, and not
enough. 6-7 min end to end does not follow from it. And the largest remaining piece of the redesign
(moving label work off the judge) is the piece U0 just produced evidence against. Sections 4, 5 and
8 stand as written but their premise is now weaker than when they were drafted, and R2 in particular
should be read as "(a) or nothing", not as an open choice.

## 4. The units, if U0 says build

- **U1 - the label-evidence pre-pass (daemon, python road).** For each residual term with no
  food-DB row and no FDC-shelf candidate: gather candidate label pages (search + fetch, serial,
  rate-limited, DEGRADE never block) into per-term evidence files, rendered into the judge's
  dossier as RANKED CANDIDATES - "all of these can be the wrong food" language verbatim. The
  judge picks and transcribes from inline evidence; its licensed open-web read remains a RIGHT
  for evidence it distrusts (registrar precedent). Placement per the estate's gather precedent:
  beside gather_price_evidence, NOT in map-preresolve.ps1.
- **U2 - mechanical grams and the buy-string hybrid.** Grams for every line the engine can
  derive (it already does; residual lines get theirs after the ruling lands, through the same
  engine + densities road). Buy strings: TEMPLATE ONLY the clean-quantity subset where the
  engine's number maps exactly ("2 lb chicken breast" class, ~5 of 7 lines on the v2
  measurement), and route every quantize-away or prep-bearing line to the judge - which is what
  the D8 scar actually forbids mechanising. Subject to Brad's ruling R1 (section 8).
- **U3 - the split map_prompt and assembler.** The judge returns rulings, new-bid cases, label
  transcriptions, and buy strings ONLY for the routed lines. assemble_mapped merges mechanical +
  judged; T7's pick-up gate, T8's by-omission sweep, the unbid hold, M3's routing: byte-for-byte.
- **U4 - the twin drill.** The same 3 shakedown slugs plus the m1 corpora, both shapes, all
  three summaries verbatim, side-by-side residual rulings against the monolithic baselines
  already in git. Success and failure bars from section 5, reported either way.

Estate mechanics apply to every unit: fixtures with 3+ elements, neuter proofs RUN and reverted
with the counts the suite printed, call-site pins (twice this build a neuter came back 0 red
because a fixture pinned a function while the bug lived at its call site), agent-def edits
followed by -Sync, CORRECTED blocks in the same commit, one unit per commit, pushed.

## 5. Success and failure, with honest bars

SUCCESS (all must hold): map lane <= 3 min for a 3-recipe residual-heavy batch (the proposal's
90-120 s is recorded as the stretch bar, not the gate); ZERO accuracy loss measured as - identical
or human-audited-equivalent residual identity rulings vs the monolithic baselines; no rise in
parks, registrar collisions, QA rejects citing mapping, or food-DB refusals; buy-string quality
attested by QA and a 20-line human read.

FAILURE (any one): map > 4 min; any identity divergence the audit rules a regression; any gate
weakened to pass. A failure is reported with its numbers and is Brad's conversation.

## 6. What does not move

Every gate and threshold; mechanical ranks, never asserts; the registrar's existence, authority,
batch road and collision re-check; T7's pick-up gate and T8's by-omission sweep; QA independence;
model pins and effort (Opus 5 / high for the judge - ruled 2026-08-25); the daemon holds every
pen; ps_invoke / py_invoke as the only marshalling roads; the closed forks in the brief.

## 7. How this could backfire, named

- The judge, no longer authoring the bulk, loses incidental context the bulk emission forced it
  to internalise. Mitigated by full-recipe context in the dossier; DETECTED by U4's side-by-side.
- Templated buy strings read robotic on the live site. Bounded by the hybrid (prose-bearing lines
  stay judged) and caught by QA + the human read.
- The label pre-pass fetches the wrong page and the judge, trusting inline evidence, transcribes
  the wrong food. The dossier language and the Atwater/provenance gates stand; refusal counts are
  the tell, reported in U4.
- U0 optimism: the probe under-measures re-ask and schema pressure. Bars in section 5 use the
  BUILT shape's numbers, never U0's.

## 8. Brad's rulings required before U1

- **R1 - buy-string ownership.** (a) hybrid per U2 (recommended: template the exact-map subset,
  judge the rest), (b) all buy strings stay with the judge (smaller win, no scar risk), or
  (c) all mechanical (contradicts the recorded D8 scar - listed only to be refused explicitly).
- **R2 - label transcription home.** (a) inside the judge dispatch from inline evidence
  (recommended: zero new agents, zero new pins), or (b) a new Fable transcription stage mirroring
  recipe-hunter-extractor (cleaner separation, but a NEW pin only Brad can mint).
- **R3 - the target itself.** If U0 lands in the 2-4 min band: build for ~8-9 min E2E, or open
  the audit's own decomposition as a sibling effort, or hold the 6-7 min target and accept that
  the honest answer may be "unreachable without relaxing a ratified constraint."
