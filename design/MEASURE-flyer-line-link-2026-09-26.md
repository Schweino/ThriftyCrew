# MEASURE: Hy-Vee flyer-line to product linker, first run against the labelled 53 (2026-09-26)

Spec: `design/PLAN-flyer-line-product-link-2026-09-26.md` (ruled 2026-09-26, "Yes, build to that bar", shadow mode).
Rule variants tried: **2**. Variant 1 (linker-v1, the plan's section 2 as written) first, unchanged after seeing its result; variant 2 on Brad's ruling, in its own section below.

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

**CORRECTION, same day: the premise of this finding is FALSE. The bottled-water cell is right.** `bottled-water` is an
`each` commodity (`grocery/commodities.json`: unit `each`, label "Bottled Water (24-pack)"), so $0.1662 is PER BOTTLE,
not per fl oz: 3.99 / 24 bottles = $0.16625 a bottle. The published row (`public/board.json` `__rows`) reads
"$0.17 each" for Hy-Vee, beside Walmart $0.10, Sam's $0.11, Baker's $0.14, Fareway $0.17, Family Fare $0.17 and Aldi
$0.20 each, all price / bottle count. The linker's 24 is the bottle count on that basis, so its `match` confirms a
correct price. Checked over the board read here (`grocery/out/comparison-2026-09-23.json`, 2,810 priced cells): 250
cells name both a count and an ounce figure. 97 are `each` cells priced per item by design and 2 are `dozen`. None of
the 151 volume or weight cells (35 fl oz, 103 oz, 13 lb) prices one item's volume as the pack (every size the store states is the pack total, and each per-unit
reproduces price / total). Over `grocery/product-urls.json`, 114 of 2,964 volume-unit links carry a count in the name
and one measure in the size field. Every one of those sizes is the pack total, and the link per-unit matches the
cell's wherever the cell exists. The two that differ (Walmart canned-green-beans, Hy-Vee fish-sticks) differ on
PRICE, not size. No code was changed. `grocery/test-pu-lib.ps1` now pins the four incident shapes (per bottle on
`each`, 24 x 16.9 = 405.6 fl oz on a volume unit). The design point above still stands in general: a linked verdict
that shares one parser with the cell it confirms cannot catch that parser's error.

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

## Variant 2 (Brad, 2026-09-26: "Both loosenings" and "Accept sets")

**Variants tried: 2** (v1 above, v2 here). **The bar is unchanged** (`wrong_links == 0 and links_made >= 20`, and 0 false
wrong-price on replay). Same frozen evidence file (blob 662ea867...), same gold (blob 945d1ede...), same board (sha256
prefix 7A8292F786373DA6). The gold was not re-labelled after v2 ran. What v2 changes, and nothing else:

- **2a, abbreviations.** A Hy-Vee name token in the map also contributes the line word it abbreviates (`Ckn` -> chicken).
  Rule 2 still wants every brand-and-family word. The map was DERIVED MECHANICALLY from the 451 candidate reads (443
  products): a pair was proposed when a name token was an ordered-letter subsequence of a line word the name lacked
  (same first letter, shorter), or the initials of consecutive missing line words. 47 pairs came out. The admission
  criterion was fixed before re-scoring: the short form is not itself an English word or another brand in the evidence
  (drops `sol`, `scrub`, `season`, and `peach`/`pch`, which are stemming artefacts), and a 2-letter short form must be
  an initialism or cited twice or more (drops `mx`, `sc`, `sb`). `bl` keeps only its initialism (black label). 38
  entries, each citing a product id and its read name, in `$script:HfAbbrev`.
- **2b, sets.** When two or more products pass rules 1 to 3 at the cell's size, the line links to the set, but only when
  every candidate that passes rules 2 and 3 at the cell's size also carries the line's exact in-window sale price. One
  off-price, off-sale or unread member refuses the set. The scorer counts a set link correct only when EVERY member is
  in the label's ids, and replays every member.

**CAUTION: the map is fitted to this evidence, not held out.** It was derived from the same 451 reads the bar is scored
on (memory `pick-the-best-run-is-selection-on-noise`). The one-ad-cycle shadow run is the first out-of-sample look.

| Arm | Lines | Links made | Wrong links | False wrong-price | Abstain on a labelled product | Correct abstain | Bar |
|---|---|---|---|---|---|---|---|
| A-no-link (today) | 53 | 0 of 53 | 0 of 0 | 0 | 39 | 14 | missed (coverage) |
| linker-v1 | 53 | 8 of 53 (15%) | 0 of 8 | 0 of 8 | 31 | 14 | MISSED: 8 is under 20 |
| linker-v2 | 53 | **18 of 53 (34%)** | **0 of 18** | **0 of 18** | 21 | 14 | **MISSED: 18 is under 20** |

v1 to v2 moved +10 links over 53 lines: 5 from the map (chicken-drumsticks and chicken-thighs via `ckn`, dog-treats via
`flvr` and `bisc`, granola via `qkr`, steak-sauce via `grmt`) and 5 from sets (bbq-sauce 3 members, graham-crackers 3,
hummus 2, peanuts 3, taco-sauce 2). No v1 link was lost and no line moved the other way. No set was refused for an
off-price member on this evidence (0 of 5 multi-product lines), so rule 4a's refusal is proved only by fixtures. v1 was
re-run through the new code from the same evidence and reproduced all 53 decisions exactly (linked id and reason).

The 21 lines v2 still abstains on: 15 have a brand or family word the name DROPS rather than abbreviates (brownie-mix
"super moist", canned-chicken "chunk breast", carrots "farms", chicken-wings and chuck-roast "Hy-Vee", dog-food "dog
food", granola-bars "bars", hot-sauce "sauce", laundry-detergent, lettuce "by Dole head", muffins "Entenmann's",
tortillas "net tortillas", trash-bags "tall kitchen", white-wine "white wine", bar-soap "soap"); 4 state no size in the
line's unit (aluminum-foil, frozen-waffles, laundry-pods, vegetable-oil); frozen-pizza's price is a cent off; bagels
read 12 oz against a "14 or 22 oz" line. Brad's ruling covered abbreviations, not dropped words, so none of these was
touched. **The linker stays in shadow and `stores.json` Hy-Vee `flyer_link` stays `shadow`.**

The bottled-water finding above is unchanged: v2 still links 56357 and the replay still says `match` on a per-unit
about 17x too high.

Labels that look questionable after v2 ran (listed for Brad, NOT re-labelled):
- `peanuts`: the SET label includes 8020 and 7726 (Cocktail Peanuts), which the commodity's own identity rule refuses, so
  no rule variant can ever link them. The label and the commodity rule disagree about what "Planters peanuts" covers.
- `bagels`: the SET label accepts four 12 and 12.4 oz products for a line that states "14 or 22 oz". Rule 3 refuses
  them by design; if the label is right, the flyer's stated sizes are wrong.

Harness for v2: `grocery/hyvee-flyer-link.ps1 -EvidenceIn grocery/hyvee/flyer-link-evidence-2026-09-26.jsonl -Variant 2`,
then `grocery/score-hyvee-flyer-link.ps1 -Arm linker-v2 -Append`, run 2026-09-26 on a worktree based at origin/main
d4d332945. Blobs (`git hash-object`): lib c0e844d48520d1c9f93f793a44cbed57a4d78119, runner
b56da4fdf2221c9b147fb4ebef88ade453082b82, scorer 23bc685d2a8fa5fce6472f25168ee38553721069, fixtures
`grocery/test-hyvee-flyer-link.ps1` a0ea1cc498ef54ce27266dffd1cb55a86100f09e (37 of 37, exit 0; mutants that drop the
off-price refusal or the map expansion are each killed by their named cases), decisions
`grocery/hyvee/flyer-link-decided-v2-2026-09-26.jsonl` 9f35f7e39806c1cfe27cd3a83e56a7a96c8244b1, cases (v1 rows
unchanged, 53 v2 rows appended) ac7b6637f106ee612bfea49fa5f600c83335a10f. The mechanical derivation was a scratch probe
and is described above rather than committed; the map's own cited entries and `Test-TcFlyerAbbrevShape` are what
survive of it.

**The shadow run is now in the daily chain**: `check-ad-cycles.ps1` fan-out lane `hyvee-flyer-link` (variant 2, paced
1.5 s, 1500 s budget, marker `FLYER-LINK-COMPLETE`), writing only `grocery/out/hyvee/flyer-links-<date>.jsonl`, which is
gitignored so capture-run's staging of `grocery/out` cannot commit it. The network half of the runner is unchanged
from v1 and was not run live in this change; its first chain run is the first live look.

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
- (v1, at the time) Not yet wired into the daily chain. Wired for variant 2 since: see the Variant 2 section above.
