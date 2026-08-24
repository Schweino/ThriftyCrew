# Deviations, recorded BEFORE the run (section 10 invariant)

Run: hunt-2026-08-24-v3-phase6b. Phase 6b, the PROVING RUN, build-order row 6b.
Started 2026-08-24, ~13:0x CDT. Brad present and directing.

## 1. TARGET TRIMMED from ~20 to 12, by Brad's order

The 6b criteria block asks for "~20 recipes, wave size 10". Brad's weekly Claude
usage was 65-80% at run start and he chose the trim, exactly as the phase-6a gate
was trimmed from four recipes to two-then-one at 65%. Wave size stays 10, so wave
1 is a full wave and wave 2 closes on drain. `--target 12`.

Recorded rather than glossed: the steady-state measurement (criterion 3) excludes
wave 1, so it will rest on wave 2's recipes, which is a thinner sample than 20
would have given. Criteria 1, 2, 4 and 5 are per-recipe or per-dispatch and are
unaffected by the count.

## 2. THE RUN'S BAND IS NOT THE PLAN'S DEFAULT BAND

Brad's stated conditions: 500-650 cal per serving, 40 g carbohydrate or less, and
50 g protein or more. The daemon's old DEFAULT_COND was 400-650 / <= 35 with no
protein rule of any kind.

This is not a deviation from the criteria block - the block never fixed a band -
but it is why the band became a run parameter before the run started. See the plan's
"CORRECTED 2026-08-24" block inside the 6b criteria, and commit 2eba1d69.

## 3. PUBLISH IS DRY RUN for this run

Brad's call at run start: no `--publish`. The wave lane runs `wave-publish -DryRun`,
which still exercises the auditor end to end. The runbook names this a legitimate
first wave. `--ledger`, `--specs` and `--costed` are EMPTY, so the LIVE ledger,
spec store and costed.json are in use, as a proving run requires.

## 4. THE EXTRACTION LADDER MAY NOT REACH RUNG 2

All 21 pool candidates that meet this band carry JSON-LD, so rung 1 (the local
27B line-split over JSON-LD lines, which DOES use the card) covers them. Rung 2
is full-page transcription for pages with no JSON-LD, and may never fire. If pass
1 escalates nothing there is no pass 2 and no `-Slots 1` restart; that is an
outcome to report, not a shape to manufacture.

llama-server started by hand at `serve.ps1 -Slots 4`, reporting 4,096 tokens per
slot and 15,179 of 16,303 MiB used - the shape section 4.3 measured. Rung 2 needs
~11,465 per slot and will correctly refuse until a narrow restart.

## 5. KNOWN, UNFIXED, NOT BLOCKING: the ingest pre-filter is narrower than a run band

harvest.py qualifies candidates at its own hard-coded 400-650 / <= 35, so a
candidate this run's band admits at 36-40 g carbs sits at `ruled:out-of-band` and
cannot be popped. Measured: 3 such candidates. 21 qualifying candidates remain
available, so it does not block this run. Recorded as a proposal for Brad.
