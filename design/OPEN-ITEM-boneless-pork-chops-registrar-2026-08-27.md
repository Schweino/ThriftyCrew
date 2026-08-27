# OPEN ITEM: the registrar approved `boneless-pork-chops` and nobody executed the ruling

Raised by the wave-3 auditor of run hunt-2026-08-27-ten, 2026-08-27. It blocks
`baked-stuffed-pork-chops`, which is otherwise audited CLEAN - macros hand-recomputed, band, protein,
card, voice and gates all green.

## What the registrar already ruled

This run's mapper proposed a NEW commodity id `boneless-pork-chops`. The commodity-registrar APPROVED
it (see `mapped\baked-stuffed-pork-chops.json`, `registrar_rulings`), having verified that the only
priced chop id, `pork-chops`, is literally **"Member's Mark Bone-In Pork Chops"** - a bone-in
purchase, not a boneless-inclusive generic. In its own words, bridging the two "would publish both a
wrong price and a wrong portion for the main protein of the dish."

It prescribed three REQUIRED edits via `add-commodity-rule.ps1`:
1. mint the id in `recipe-board-everyday` + `recipe-commodities`;
2. add the dupe-allowlist pair;
3. add `\bboneless\b` to `pork-chops`' excludes.

**None of the three happened.** `boneless-pork-chops` has 0 occurrences in `grocery\commodities.json`,
`grocery\recipe-commodities.json`, `grocery\out\recipe-board-everyday.json`,
`grocery\commodity-dupe-allowlist.json` or `grocery\out\smp-feed.json`, and `pork-chops`' excludes
still lack `\bboneless\b`.

## What I did wrong, and what I did about it

I added a vocabulary row `Boneless Pork Chops -> pork-chops` with the note "a NAME, not a new
commodity" - the exact bridge the registrar had ruled against, asserting the opposite of a ruling
sitting in this run's own artifacts. My check was "is the bid priced on the live board?" I never
asked whether the registrar had already ruled on that bridge, and I read `boneless-pork-chops`
coming back "not found" among priced bids as *point it at the generic* rather than *there is a
reason this does not exist yet*.

Consequence while that row stood: 71% of the batch cost (3174 g, $22.88 of $32.39) was charged
against `board:pork-chops:walmart`, crowned product "Pork Assorted Loin Chops, **Bone-In**, 8 count
Tray" at $3.27/lb, and the card told the reader "Buy 7 lbs: $22.89" for a product that at that price
is bone-in. Followed literally, the reader comes home roughly 30% short of boneless meat. It survived
every plausibility gate because $3.27 sits inside the real boneless spread - the
"an agreeing number escapes scrutiny" failure mode exactly.

The row is REMOVED (text-level, 310 -> 309, every surviving row byte-identical). The name now does
not resolve, so the recipe refuses at the spec build instead of publishing a wrong price. That is the
correct interim state: per the Recipe Hunter skill, a run never edits commodity files, and a
registrar-approved id is a flagged follow-up with the ingredient mapping to null meanwhile.

## What executing it needs

Boneless prices were ALREADY gathered and adjudicated (hunt-2026-08-26-ten price-evidence batch-5):
Sam's Member's Mark Boneless Center Cut Loin Chops $2.98/lb, Family Fare NY Boneless Value Pack
$2.995/lb, Hy-Vee $3.96, Fareway $3.99. Note the Family Fare row is currently crowned INSIDE the
pork-chops cell - a boneless product on a bone-in id, which is the leak the exclude edit closes.

1. `add-commodity-rule.ps1` for the three edits exactly as ruled.
2. Re-add the vocabulary row pointing at `boneless-pork-chops` (NOT at `pork-chops`).
3. Wire the new id's board rows from the batch-5 evidence.
4. Re-cost, `sync-recipesdb-cost` BEFORE propagate, rebuild the spec cost lines.
5. Scoped re-audit: `wave-preaudit.ps1 -RunDir <run> -Wave 3 -Slugs baked-stuffed-pork-chops`.

Until then `baked-stuffed-pork-chops` cannot publish, and that is the right answer.
