# MEASURE: Hy-Vee flyer-line to product linker, first run against the labelled 53 (2026-09-26)

Spec: `design/PLAN-flyer-line-product-link-2026-09-26.md` (ruled 2026-09-26, "Yes, build to that bar", shadow mode).
Rule variants tried: **1** (linker-v1, the plan's section 2 as written). No rule was changed after seeing the result.

## Knowledge consulted

Searched "flyer line product link Hy-Vee" (skills, memory, rules, machinery). Used: `grocery/pu-lib.ps1` ("THE single per-unit implementation. Dot-source it; never re-type it.", so the cell-size check is Get-LinkPerUnit); memory `hyvee-store-identity` (storeId and locationId select different halves of the response and move together, so both come from hyvee-store-lib); `grocery/link-sibling-lib.ps1` ("the ad-range rule reads the first word of the first alternative", the precedent for the brand an 'or' alternative inherits); `.claude/rules/measurement.md` (one row per case per arm, a matcher that abstains is scored on what it skipped, cite blobs).

## The bar (quoted from the plan, written before any run, not changed)

> **Precision bar: 0 wrong links out of the links made, with at least 20 links made.** ... Written as:
> `wrong_links == 0 and links_made >= 20`.
> **False-wrong-price rehearsal:** ... Bar: **0 `wrong-price` verdicts on lines whose label says the link is right.**

## Result

| Arm | Lines | Links made | Wrong links | False wrong-price | Abstain on a labelled product | Correct abstain | Bar |
|---|---|---|---|---|---|---|---|
| A-no-link (today) | 53 | 0 of 53 | 0 of 0 | 0 | 39 | 14 | missed (coverage) |
| linker-v1 | 53 | **8 of 53 (15%)** | **0 of 8** | **0 of 8** | 31 | 14 | **MISSED: 8 links is under the floor of 20** |

Precision held (0 wrong over 8 links), and so did the rehearsal (8 of 8 replayed `match` through the unchanged
`Resolve-TcRereadVerdict`). Coverage did not: 8 of 53 against a floor of 20. **The linker stays in shadow.** Nothing
in it can reach a board, and `stores.json` Hy-Vee `flyer_link` refuses `live`.

**The labels are PROPOSED, awaiting Brad's review.** Every number above is conditional on them. Label mix over the 53:
26 single products, 13 sets (several flavours at one flyer price, all at the cell's size, any one of which proves the
line), 14 NO-MATCH (no read product proves the line). The labels were written before the linker ran on these reads.

## A finding the bar does not measure: one of the 8 matches confirms a wrong board cell

`bottled-water`: the line is "Hy-Vee spring water, 24 pk. bottles 16.9 fl. oz., $3.99". The board cell reads
$0.1662/fl oz, which is 3.99 / 24, meaning the 24-pack was read as 24 fl oz. The true figure is 3.99 / 405.6 =
$0.0098/fl oz, so the published per-unit is about 17x too high. The linker read the product name "Hy-Vee 24Pk Spring
Water" (size field "16.9 fl oz") through the same `Get-LinkPerUnit` and got the same 24, so the product sits "at the
cell's size" and the replay says `match`. The link itself is right (product 56357 is the product the line prices), and
the bar scores it correct. **But a live link here would CONFIRM a wrong price.** This is the "an agreeing number
escapes scrutiny" shape: the check and the thing it checks share one parser. Before any live switch, a linked verdict
needs a size check that does not go through the same reader, or this shape needs its own must-fire fixture. Recorded
as a finding. The linker was not changed.

## Why 31 labelled lines were not linked (from `grocery/hyvee/flyer-link-cases.jsonl` plus the decided file)

- **A family word is missing from Hy-Vee's name: 19 lines.** Hy-Vee abbreviates and drops brands: "Hy-Vee Ckn Thighs
  Fam Pk" (no "chicken"), "BC Dark Choc Brownie Mix" (no "Betty Crocker"), "Qkr Protein Granola", "Franks Original
  RedHot" against "Frank's Red Hot", "CSM Sauvignon Blanc" against "Chateau Ste. Michelle white wine", "Chicken Wings
  Fam Pk" (no "Hy-Vee"). Rule 2 ("every brand and family word") refuses all of these by design.
- **Ambiguous at the cell's size: 5 lines** (bbq-sauce, graham-crackers, hummus, peanuts, taco-sauce). Several
  flavours at the same flyer price and size. Rule 4 requires exactly one product, so it abstains.
- **No size stated in the same unit: 4 lines** (aluminum-foil "75 sf", frozen-waffles "24 ea Box", laundry-pods "2.46
  lb" for a 60 ct line, vegetable-oil "40 oz Bottle"). The size field is used only when it is one plain measure, and
  these are not.
- **Price differs by a cent: 1 line** (frozen-pizza reads 3 for $10.00, the line says $9.99).
- **Size outside the line or none at the cell's size: bagels and bar-soap.** Bagels read 12 oz against a "14 or 22 oz"
  line whose 4 ct cell basis is per each. Bar soap fails on "soap", which is not in the names. (19 + 5 + 4 + 1 + 2 = 31.)

Changing any of these is a new rule variant (variant 2). It is Brad's call which way to go, and the plan says the next
run states the variant count. The largest lever is rule 2, where an abbreviation map would be a second parser to keep
honest. Rule 4 is the next largest (a set of equally priced flavours all prove the price), and that relaxation is
exactly what the bottled-water finding says to be careful with.

## How it ran (harness, blobs, inputs)

Harness: grocery/hyvee-flyer-link.ps1 then grocery/score-hyvee-flyer-link.ps1, run 2026-09-26 on a branch based at origin/main commit 763c001e2 (blobs below; cite blobs, since the landing rebases).

- Harness: `grocery/hyvee-flyer-link.ps1` (collect, then decide with `-EvidenceIn`), `grocery/hyvee-flyer-link-lib.ps1`
  (the rule), `grocery/score-hyvee-flyer-link.ps1` (the scorer and replay), on branch base origin/main 763c001e2.
  Blobs (`git hash-object`): lib 6acb81da6601d9279dfd72306819ec562c7efaae, runner 0c1354436d47da3ca2d6f6f46b1d5f6abc22b43b,
  scorer a92058ae517c6d08b3e03a7aae1e8cd2ede20f99, fixtures `grocery/test-hyvee-flyer-link.ps1`
  2970d50cb9cc00eb6ffaa4d3d4469244e4d41ba5 (24 of 24, exit 0), `grocery/flag-verify-lib.ps1`
  d28f673cb61228e97768db9d4c7e8cc6f6602cff, `grocery/pu-lib.ps1` ff69dea376da77cb168f532b4d509cb8fe6061e4.
- Board: `comparison-2026-09-23.json` (the newest in the main checkout, sha256 prefix 7A8292F786373DA6). The 53 lines are
  exactly the Hy-Vee cells `Test-TcFlyerLineNamesNoProduct` marks.
- Reads: 2026-09-26, storeId 1466 (Omaha #02), inside every line's ad window (the windows end 2026-09-27). Hy-Vee search
  (8 per term) plus product-urls.json, 451 candidates, 443 distinct products, 451 of 451 GraphQL reads answered,
  0 threw, 0 failed searches, paced 1.2 s. File `grocery/hyvee/flyer-link-evidence-2026-09-26.jsonl`
  (blob 662ea867fd4d2ac5d232c2c693c62fe79faa432f).
- Labels `grocery/hyvee/flyer-link-gold.jsonl` (blob 945d1edec01af4b5b6939fea2a2bc3d1e3bc3b5f), decisions
  `grocery/hyvee/flyer-link-decided-2026-09-26.jsonl` (868a70d2383a8673e32a61973a48a5dd3d7ecde7), one row per line per arm
  `grocery/hyvee/flyer-link-cases.jsonl` (6a1cd5b3d805f59702d6f432d60f903ade223f32). Every total above is derived from the
  cases file.
- Deviation from the plan, stated: candidate source 2 ("every Hy-Vee product id the board already holds for that
  commodity") is read from `product-urls.json` only. `hyvee-regular-*.json` rows carry no commodity id, so they cannot be
  keyed to a line without a matcher. This can only cost coverage, never precision.
- Not yet wired into the daily chain. The shadow run is `grocery/hyvee-flyer-link.ps1` by hand, and it writes
  `grocery/out/hyvee/flyer-links-<date>.jsonl`. The plan's "one full ad cycle in shadow" needs a scheduled call, which is
  a chain change and is left for its own landing.
