# PLAN: Certification that does not re-run itself - what the cert treadmill cost, and the two fixes

Date: 2026-08-16. Status: MEASURED, not built. Brad ruled "finish the run first" - this is the write-up
for a later pass, deliberately recorded while the numbers are still exact.
Origin: the fresh-broccoli / fresh-spinach repair, and the cream-cheese rebase that followed it.

## 0. What happened

Seven recipes were re-costed onto fresh produce bids; five were rebased onto the 1/3-fat cream cheese
food-DB row. Every reader-facing number was correct after the first pass. Certification then ran **three
times**, and every re-run was triggered by edits to `writer_notes` - a field **no renderer reads**.

Verified, not assumed: `writer_notes` appears in `build-v2-spec.ps1`, `build-run-specs.ps1`,
`spec-guards.ps1` and `annotate-writer-note.ps1`. It appears in NO renderer - not `build-card2.ps1`, not
`engine\build-cards.ps1`, not `engine\publish.ps1`, not `lib\render-tokens.ps1`. A wave-3 auditor
independently confirmed 0 occurrences in a dry-built card.

## 1. The measured cost

| pass | subagent tokens |
|---|---|
| commodity-registrar ruling | 49,695 |
| source-QA, initial 2 recipes | 48,431 |
| wave 1 audit (whole-wave) | 142,458 |
| wave 3 audit (whole-wave) | 195,857 |
| wave 4 audit (new wave) | 172,345 |
| **source-QA re-cert round 1** (4 specs) | **94,930** |
| **source-QA re-cert round 2** (5 specs) | **123,385** |
| **source-QA re-cert round 3** (4 specs) | **98,681** |
| total | **925,782** |

**317,000 tokens - 34% of the run - went to re-certifying specs whose reader-facing bytes never moved.**
Each round was correct to demand: the mechanism genuinely could not tell that the edit was internal.

## 2. Root cause: freshness is mtime over the whole file

`wave-publish.ps1` P1b (line ~416) reads `(Get-Item $auditPath).LastWriteTime` and requires it to beat
every spec's `LastWriteTime`. The batch auditors apply the same rule to source-QA certs. The comment at
line 102 states the intent exactly right - *"did the auditor see the current bytes"* - and mtime answers
that question honestly. The defect is not the rule, it is the GRANULARITY: **the whole file is the unit,
but only part of the file is what the certificate is about.**

So an annotation correcting a stale internal note - the very act of making the record honest - invalidates
the certificate that says the recipe is faithful to its source. Truthfulness of provenance and fidelity to
source are different properties, and today they share one gate.

## 3. Fix 1 - cert the SURFACE, not the file

Record in each cert a hash over the fields the certificate is actually a statement about, and gate on the
hash rather than on mtime:

    ingredients_grams, ingredients_display, scaler, stat, cost_batch, cost_batch_true,
    cost_per_serving, cost_per_serving_true, cost_pantry_add, cost_first_run, cost_lines,
    cost_note_html, cost_closing_html, shop_smart, make_it, intro_html, portion_html,
    credit_html, upsell_html, head, name, slug, servings, protein, visibility

EXCLUDING `writer_notes` (and only that, for now). A cert is fresh iff its recorded surface hash equals the
spec's current surface hash; fall back to mtime when a cert carries no hash, so legacy certs still gate.

**This is not a new idea in this estate - it is the existing idiom, one layer up.** `published-hashes.json`
already gates publish on a SHA1 of built content; `propagate-stamps.json` already gates propagation on a
SHA1 of the spec file. Certification is the one link in the chain still gating on a timestamp.

Effect on this run: all three re-cert rounds would have been no-ops. The surface hash never moved.

**The caveat that must travel with it.** Excluding a field from the hash makes later edits to that field
invisible to the gate. That is safe for `writer_notes` *because nothing renders it*, which was verified
rather than assumed. It would NOT be safe for `shop_smart`, `cost_lines`, or anything else on the list
above. Any future addition to the exclusion set needs the same verification, written down.

## 4. Fix 2 - a deterministic linter BEFORE the expensive reader

Most of what rounds 2 and 3 caught was mechanically detectable. I wrote the detector ad hoc twice during
the run and it found every case both times. Promote it to `audit-stale-notes.ps1`:

- flag any `writer_note` stating a calorie/macro figure that is not the spec's own `stat` value and is not
  inside an attributed source cross-check
- flag false wiring claims: `unwired`, `is a FLOOR until`, `item_id null`, `no usable row`,
  `has NO row in db`, `maps to full-fat`, `did NOT swap`
- must-fire fixtures from this run's real defects; clean twins for the legitimate cases, which are the
  trap: band bounds (400/650), source-page cross-check figures (485 creamy-tuscan, 450 keto-turkey,
  472 sheet-pan), and rounding twins (580.9 -> 581, 446.7 -> 447). A linter that flags those cries wolf.

A ~2k-token guard replaces a ~100k-token QA round for this entire class, and it finds the whole class in
one pass instead of the three it actually took.

## 5. Fix 3 - split the severity

With `writer_notes` outside the cert surface, a stale note cannot fail a certificate at all. The division
becomes honest:

- **source-QA** rules on what ships: is this the recipe we found, are the macros right, does the copy match
  the basis.
- **audit-stale-notes** rules on internal provenance: does the file's own record still tell the truth.

Both still block a wave. Only one of them costs a live page fetch and a full macro recompute.

## 6. What NOT to rely on

"Finish all edits, then certify" is the correct process rule and it is the weakest fix. It was known and
violated three times in one run, by me, while holding the very list of findings that made each new edit
necessary. Mechanisms beat discipline, and a mechanism that makes the wrong thing free is better than a
rule that makes it forbidden.

## 7. Second-order finding, same class

`propagate-recipes.ps1` line 152 caps its `-DryRun` listing at `Select-Object -First 30` with no "and N
more" notice. On a 49-spec dirty set it printed 30 and the last line looked like the end of the list. I
reported a republish count of 11 to Brad from that output; the true number was 19, with 17 belonging to
another session's uncommitted work. **A silent cap on an operator-facing listing is a wrong number wearing
a right number's clothes** - the estate's own "no silent caps" rule, unapplied here. One line to fix; not
touched during this run because that file was being concurrently edited by another session.

## 8. Related trap worth a standing note

`Select-Object -First N` raises `StopUpstreamCommandsException` and **terminates the upstream script**.
Piping a writer script through it (`.\tool.ps1 -Apply | Where-Object {...} | Select-Object -First 1`) kills
the script after its status line and before its write. Six annotation writes were silently discarded this
way while reporting success, because the status line prints before the write and only the trailing
`wrote <path>` line proves the write happened. One of the six would have shipped a recipe carrying an
internal instruction to reverse Brad's own ruling.

Cheap hardening for every writer in the estate: **emit the summary AFTER the write, not before**, so a
truncated pipeline cannot produce a success-shaped output with no effect. Cheaper still: never pipe a
writer's output through `Select-Object -First`.
