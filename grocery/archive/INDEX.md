# grocery\archive - retired scripts and data (archive sweep 2026-07-26)

Nothing in here is called by live automation (verified by repo-wide grep before each move).
Superseded scripts live at this level with their current replacement named; completed one-shot
jobs are in `one-off\`; consumed input data is in `data\`.

## Superseded (replacement in parentheses)

- `import-walmart-prices.ps1` - folded Walmart browser-capture prices into walmart-regular files; carried the whole-pack-vs-per-unit trap docs. (now: `walmart-capture-reducer.js` + `import-walmart-batch.ps1` + `build-walmart-deals.ps1`)
- `import-bakers-prices.ps1` - folded Baker's browser-capture (UPC-matched) prices into bakers-regular files. (now: `pull-regular-bakers-api.ps1` via the sanctioned Kroger API)
- `walmart-browser-pull.js` (was hyvee\) - in-tab __NEXT_DATA__ Walmart price capture. (now: `walmart-capture-reducer.js` + `import-walmart-batch.ps1` + `build-walmart-deals.ps1`)
- `bakers-browser-pull.js` (was hyvee\) - in-tab Baker's shelf-price capture, BK.dump() workflow. (now: `pull-regular-bakers-api.ps1`)
- `transform-bakers-links.ps1` - Baker's-only raw-link-download transformer. (now: generic `transform-store-links.ps1`)
- `publish-tracker-index.ps1` - published the old tracker index page. (now: `build-trend-index.ps1` + `publish-trend-pages.ps1`)
- `resolve-ff-links.ps1` - first-gen Family Fare "See item" resolver via Freshop search. (now: `fix-links-ff.ps1` + `resolve-ff-boardmatch.ps1`)
- `resolve-ff-pricematch.ps1` - re-picked FF products whose per-unit matched the board price. (now: `fix-links-ff.ps1` + `resolve-ff-boardmatch.ps1`)
- `resolve-walmart-links.ps1` - offline Batch-1 Walmart chip resolver off staples500\walmart-itemids.json. (now: the standard worklist flow, `resolve-worklist.ps1` + per-store resolvers per grocery\README.md)
- `pull-ff-brands.ps1` (was brands\) - brand-pilot FF/Freshop puller, single hardcoded item set. (now: `pull-ff-brands-batch.ps1 -ConfigPath`)

NOT moved despite being on the audit list: `import-sams-prices.ps1` - still referenced (non-comment)
by `out\r300\build-capture-worklist.ps1` and the generated `meal-prep\r300\board-capture-worklist.json`
that drives the still-open R300 capture worklist. Archive it when that worklist closes
(replacement is `build-sams-deals.ps1`).

## one-off\ - completed one-shot jobs (kept for the record; safe to read, pointless to run)

- `add-cheaper-verified.ps1` - promoted two genuinely-cheaper linked products into the regular files so their pins could die.
- `apply-newitem-fills.ps1` - wrote the validated new-item fills (out\newitem-accepted.json) into each store's regular file.
- `assemble-batch2.ps1` ... `assemble-batch14.ps1` (13 files) - brand-pilot batch assemblers, one per config/bucket slice of the brands run.
- `assemble-cross.ps1` - cross-store assembly for the brand pilot (FF + Walmart/Sam's buckets).
- `audit-link-price-match.ps1` - one-time sweep comparing every linked product's per-unit to its board price (LinkPU math). Its LinkPU copy was patched by fix-linkpu-multipack.ps1, which is archived beside it.
- `audit-multipack-size.ps1` - flagged rows whose name said multipack but whose size recorded one unit.
- `audit-pins.ps1` - explained every override pin that disagreed with the engine (pins are all gone now).
- `backfill-restored-for.ps1` - stamped `restored_for` onto restored rows written before heal-missing-products recorded it.
- `build-board-v2.ps1` - the browse-first A/B redesign board (rendered to a beta page, never replaced the live board).
- `dedup-candidates.ps1` - cleaned the staples-500 candidate list of already-covered items before registration.
- `fill-newitems-ff.ps1` - filled Family Fare gaps for the 27 new 2026-07-14 commodities via Freshop.
- `find-six.ps1` / `fix-remaining-six.ps1` - located and fixed the six broken cells on the published tracker page.
- `fix-bakers-verified.ps1` - corrected Baker's cells verified in-store at Saddlecreek (regular-vs-discount disease).
- `fix-drift-links-ff.ps1` - re-pointed FF "See item" links at the product the board actually priced.
- `fix-drift3.ps1` - the last three board-vs-linked-product disagreements, store-verified 2026-07-14.
- `fix-linkpu-multipack.ps1` - patched LinkPU in its 4 host files to read pack counts from product names (bottled-water 24-pack bug).
- `fix-match-collisions.ps1` - closed the order-dependent match collisions found by audit-match-contested.
- `fix-pin-links.ps1` - corrected the links behind the last override pins (store-verified 2026-07-14).
- `fix-product-urls-open3.ps1` - root-cause fix in product-urls.json for the gelatin/yeast numbers that survived every other fix.
- `get-tracker.ps1` - pulled the tracker page HTML from Ghost for inspection.
- `heal-ff-file.ps1` - restored the 210 rows a rate-limited 380-row FF pull overwrote (2026-07-14 incident).
- `merge-fallback-research.ps1` - folded browser-researched everyday prices (out\fallback-research.json) into the everyday files.
- `merge-new-staples.ps1` - merged new-staples-2026-07-12.json (top-100 expansion) into commodities/categories/search.
- `merge-new-staples2.ps1` - merged new-staples2-{a,b,c}.json (200-item expansion) + cross-guard fixups on old includes.
- `patch-ff-two.ps1` - hand-patched two FF brand-pilot bucket entries.
- `probe-ff-brands.ps1` - raw Freshop probe that proved FF exposes brand data (the brand pilot's feasibility check).
- `gen-brand-pilot-data.ps1` - generated the brand-pilot prototype dataset from out\brands\ff-brands.json.
- `promote-pantry-items.ps1` - promoted ~165 recipe-only commodities into board pricing.
- `propose-floor-id-map.ps1` - evidence-gated mapping proposals for recipe-floor-id-map.json (2026-07-23).
- `publish-beta.ps1` - published the board-v2 embed to the noindex beta slug.
- `resolve-bakers-burst.ps1` / `resolve-bakers-burst3.ps1` - second/third Baker's BLR link-resolve passes (Akamai-wall cooldown bursts).
- `resolve-bakers-from-blr.ps1` - converted BLR board-match output into merge-format store-bakers-urls.json.
- `resolve-instacart-from-blr.ps1` - converted ILR iframe output (Aldi/Fareway) into merge-format store-urls files.
- `restore-ff-newitems.ps1` - restored the 24 new commodities dropped by the partial 2026-07-14 FF pull.
- `test-pulib.ps1` - known-answer test battery for Get-LinkPerUnit, used while landing pu-lib. NOT the live `test-pu-lib.ps1` (with hyphens), which stays in grocery\.
- `test-pulib-differential.ps1` - differential proof that a pu-lib change moved no existing answers.
- `test-headless.ps1` (was hyvee\) - probe proving Hy-Vee's GraphQL answers without a browser session.
- `verify-links-hyvee.ps1` - opened every stored Hy-Vee link to prove it showed the claimed product.

## data\ - consumed one-time inputs

- `new-staples-2026-07-12.json` - the 70-commodity top-100 staples expansion; merged by one-off\merge-new-staples.ps1.
- `new-staples2-a.json` / `-b.json` / `-c.json` - the 200-item expansion (63+52+85 ids); merged by one-off\merge-new-staples2.ps1.
- `new-items-2026-07-14.json` - the 27 cleaners/pantry commodities added 2026-07-14.
- `out_embedtest.html` - throwaway embed-CSS test page for the tool chrome-hiding styles.

NOT moved despite being on the audit list: `not-carried.json` - live code reference in
`build-deals-page.ps1` (renders the "Doesn't carry" cell state).

## Related sweeps (same date)

- `meal-prep\archive\root-artifacts\` - meal-prep root leftovers: the r100-era audit-group A-E JSONs, expansion-proposal.json, recipes-90.json, the _sample-recipe html pair, recipe-100-project.md, the legacy recipes\ dir, and the HELD cheap-day tool trio (cheap-day-tool.html + build-cheapday-data.ps1 + cheapday-data.generated.js - built, never shipped).
- `out\archive\` (gitignored) - aged out\ snapshots: candidates-*.json older than 7 days, the after-*-2026-07-15 onboarding-vet series, vettmp\, and regression-inputs\scratch-out (regenerated by every regression-test run). run-daily-local.ps1 now rotates candidates files older than 30 days in monthly and purges archive files older than 120 days.
- `out\fareway\` flyer JPGs (~89 MB) deliberately NOT touched: weekly/monthly capture inputs, already gitignored.
