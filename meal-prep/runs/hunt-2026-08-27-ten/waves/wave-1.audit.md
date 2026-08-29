NO-GO
scope: mediterranean-chicken-w-marinade (re-audit after recost cd3036a6; supersedes the 2026-08-27 GO)

# Wave 1 RE-audit - hunt-2026-08-27-ten (mediterranean-chicken-w-marinade), 2026-08-29

Battery: waves\wave-1.preaudit.json generated 2026-08-29T10:51:20, scoped, 16 checks, 0 failed,
exit 0 with WAVE-PREAUDIT-COMPLETE. Freshness: ingredients.json 08:09:14 -> spec 10:47:23 ->
report 10:51:20, nothing moved since. The battery is green and it is still a NO-GO, because the
defect is one the battery has no check for.

### Blocker 1 (shared-data): the recost resurrected "Buy 5 6oz can, draineds" - the 08-27 Blocker 2 fix was never committed

Today's spec (meal-prep\db\recipes\mediterranean-chicken-w-marinade.json, line 68) reads:

    Buy 5 6oz can, draineds: $9.84.

This is byte-for-byte the garbled label the 06:10 audit of 08-27 blocked on, and which the 06:18 GO
verified repaired "AT THE SOURCE". The history shows what happened:

- No commit of meal-prep\db\ingredients.json has EVER contained "6oz drained-weight can"
  (git log --all -S finds zero hits). The black-olives row has said buy_pkg_label
  "6oz can, drained" since it was born in e3fed9f0 and says so right now.
- The 08-27 repair fixed the label in the WORKING TREE, rebuilt the spec, and the spec fix
  landed in commit 8db19121 - but the ingredients.json edit was lost before it was committed
  (the ~07:00 bot's autoStash rebase rewriting uncommitted files is the known mechanism for this).
- Today's recost (cd3036a6) re-rendered the buy strings from the unfixed source. The renderer
  pluralizes buy_pkg_label by appending "s" for count > 1, so "6oz can, drained" + "Buy 5"
  = "draineds" again. Repo sweep: this is the only spec carrying the string.

FIX (owner: the shared ingredients DB, then a recipe-local rebuild):
1. meal-prep\db\ingredients.json, black-olives row: buy_pkg_label "6oz can, drained" ->
   "6oz drained-weight can" (pluralizable noun last, per the 08-27 ruling). COMMIT IT this time,
   in the same commit as the spec rebuild, so the fix cannot be stripped from under the spec again.
2. Recost/rebuild this slug so the cost line renders "Buy 5 6oz drained-weight cans: $9.84."
   (price is unchanged; only the label re-renders). Then scoped re-audit with -Slugs.

## What the recost moved, verified clean (everything except the blocker)

The cd3036a6 diff touches exactly: the olive buy label (the blocker), the lemons line
(2.54/2.72 -> 2.80/3.00, 6 lemons at $0.50 each - shelf-plausible), pantry seasonings
(0.32 -> 0.35), the three cost-tier lines, the six cost_* fields, and scaler.cost. Nothing else.

- COST CHAIN: internally coherent by recompute: 56.78/14 = 4.06 exactly; 63.65/14 = 4.55 exactly;
  63.65 + 10.79 = 74.44 exactly; scaler.cost 63.65 matches cost_batch_true. Battery
  cost reconciliation, plausibility, and line coverage all clean; 0 unpriced, 0 uncarried.
- STALE LITERALS: grep of the spec for every old figure (4.04, 4.52, 56.49, 63.34, 73.94, 10.6,
  2.54, 2.72, 0.32, 4.05) finds zero survivors. cost_closing_html uses the {{cost_ps}} template,
  so its per-serving figure tracks automatically.
- MACROS: untouched by the recost (diff confirms no macro field moved); the 08-27 verification
  (560.9/51.8/16.1/34.2 vs stat 561/52/16/34, band clear with margin) stands on today's bytes -
  battery macro recompute green again today.
- STAT-PROSE (08-27 Blocker 1): still fixed. Zero "51.8"/"16.1" in the spec;
  audit-spec-contradictions clean.
- UNBID_LINE (new gate 120a26c1): all 13 scaler lines carry a resolving bid (verified directly,
  and audit-unbid-ingredients clean n=1), so feed-covers-published will not refuse this card
  once the blocker is repaired.
- MAPPING / PROTEIN / CARDS / VOICE / GATES: unchanged since 08-27; recipes-db -DryRun green,
  P8 endpoint + feed probes green (565 recipes, feed generated 2026-08-29T09:16:24).

## Advisories (not blocking)

- Carried forward unchanged from 08-27: two shopping stories on one card (prose "three 15 oz cans"
  artichokes / "three 14.5 oz cans" olives vs engine buy strings - both plans cover the batch);
  the artichoke display line's "drained" beside a gross-basis figure; the "w/" in the title.
- For the battery owner (process): the battery has no check that catches a garbled buy_pkg_label
  render - the dash sweep, structural compare and cost reconciliation all pass over "draineds".
  Both times this defect was caught by an auditor reading the cost lines. A cheap check exists:
  flag any buy string whose pluralized label ends in a non-noun token (", draineds", "-eds", etc.)
  or simply grep built cost lines for "draineds?"-style regressions against a bad-render list.
- For the repair process (process): a source repair verified only in the working tree is not a
  repair. The 08-27 GO was correct about the bytes it saw, but the estate's known
  uncommitted-file hazards (the 07:00 bot's autoStash rebase) mean a repair is only durable
  once committed. Verify the COMMIT, not just the file.

## Verdict

NO-GO. One blocker: the black-olives buy_pkg_label regression, shared-data, fix in
ingredients.json + spec rebuild + commit both together. Everything the one-cent recost was
supposed to be checked for is clean; the recost itself is sound. The blocker is a 2-line repair
and a scoped re-audit away from GO.
