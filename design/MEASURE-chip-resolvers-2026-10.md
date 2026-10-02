# MEASURE: do the two headless chip resolvers clear the W8 bar? (2026-10-02)

Plan: `design/PLAN-browser-refresh-hardening-2026-10-02.md`, W8 step 1. Measurement only: nothing is wired,
nothing ran in a landing checkout, and nothing here changes a resolver.

Harness: `grocery/resolve-familyfare-urls.ps1` at blob e8f4996aaefaec7e2d28ab0b5098beeb37bb5e46 and
`grocery/resolve-chips-hyvee.ps1` at blob 4528d4fedfab7c329a794588375e330cea2eab6f, run 2026-10-02 in a scratch clone;
the exact commands are in the method section below.

## Question

`grocery/out/url-worklist.json` holds the product-link chips the browser task never reaches. Two of the four stores
have server feeds and an existing headless resolver. Does either resolver clear the bar below on today's chips?

## Bar (written before the run, verbatim from the plan)

> wire a resolver into the daily chain only if it resolves at least half its store's chips with zero wrong links on a
> 10-chip hand check.

In units: resolved / store chips >= 50%, AND wrong = 0 among the hand-checked resolved links (10, or all if fewer
than 10). A link that could not be loaded is UNCHECKED: counted, never right, never wrong.

"Right" means the opened page is the right product for the chip's COMMODITY (the brief's criterion). A second,
stricter column records whether the link opens the exact BOARD ITEM the cell prices
(`build-chips-from-tileintegrity.ps1`: "the thing the link MUST open, because the board's price describes it"). That
column does not enter the verdict. It is recorded because it matters for wiring.

## Inputs

| Input | Identity |
|---|---|
| `grocery/out/url-worklist.json` (main checkout, read only, gitignored) | `generated: 2026-10-01`, file written 2026-10-01 08:36, sha256 `57D3568D70392C35E136A57CC6478A04AF133730D0ADDFE5E6D215F8D44C050C` |
| Board the Hy-Vee adapter read: `grocery/out/comparison-2026-09-30.json` (seeded copy, newest in main) | sha256 `D3C47B7615DCD01BE9944AF78579B6A7EB6F0E14EB644A55C31E5C59E6A3ECD2` |

Chips per store, recounted from the worklist (157 total, matching the plan's figure): Family Fare 65, Hy-Vee 41,
Aldi 28, Fareway 23.

## Harness

Blobs (`git rev-parse HEAD:<path>` at the worktree base):

| Path | Blob |
|---|---|
| `grocery/resolve-familyfare-urls.ps1` | `e8f4996aaefaec7e2d28ab0b5098beeb37bb5e46` |
| `grocery/resolve-chips-hyvee.ps1` | `4528d4fedfab7c329a794588375e330cea2eab6f` |
| `grocery/build-chips-from-tileintegrity.ps1` (shape the Hy-Vee adapter copies) | `442d11364bbcaf6aa655ecccf3b5909e785611c2` |
| `grocery/search-terms-lib.ps1` | `61a2de891c7a5d0876ee21b7c241f498890b4558` |
| `grocery/commodity-search.json` | `7edf03fd345f31bc2122ac206b322b93b10ad6b8` |
| `grocery/commodities.json` | `74126abde9b4b06dbb5208dca6323d947ed4dfca` |
| `grocery/recipe-commodities.json` | `3763e070bbfb3d9a59cbd255f6446b0810c7a0f8` |
| `grocery/pu-lib.ps1` | `ff69dea376da77cb168f532b4d509cb8fe6061e4` |
| `grocery/hyvee-store-lib.ps1` | `59d91acaed34f33457947f48030f12ff9606b428` |
| `ops/seed-worktree.ps1` | `72132a8354309a1082401613c13a6219acbef0d4` |

Commands, in order (PowerShell 5.1; `$sp` is the session scratchpad):

```
git clone --quiet --no-hardlinks <this worktree> $sp\w8-clone
powershell -NoProfile -File ops\seed-worktree.ps1 -Target $sp\w8-clone -Source C:\Codex\ThriftyCrew
    # exit 0, SEED-WORKTREE-COMPLETE seeds=36 copied=36; url-worklist.json arrived byte-identical (same sha256)
powershell -NoProfile -File $sp\w8-hyvee-chips-from-worklist.ps1 -Root $sp\w8-clone
    # scratch adapter, exit 0: writes out\url-inputs\chips-hyvee.json from the worklist's Hy-Vee section
powershell -NoProfile -File grocery\resolve-familyfare-urls.ps1              # in the clone; exit 0
powershell -NoProfile -File grocery\resolve-chips-hyvee.ps1 -Apply           # in the clone; exit 0
```

**The Hy-Vee adapter is part of the harness.** `resolve-chips-hyvee.ps1` does not read the worklist. It reads
`out\url-inputs\chips-hyvee.json`, which only `build-chips-from-tileintegrity.ps1` writes (from `tile-integrity.json`),
and the seeded copy was dated 2026-09-05. The adapter builds the same `{id,q,match,size,pu,unit}` shape for the 41
worklist chips. `q` is `Get-PrimarySearchTerm` (the builder's `[string]$terms.$id` joins multi-term ids); `match`,
`size` and `unit` come from the board's Hy-Vee cell, as in the builder; `pu` is the worklist's `price_per_unit`. 4 of
the 41 ids have no Hy-Vee cell on the 09-30 board and fall back to the worklist's `board_item` with an empty size.

Hand check: each resolved URL rendered in the desktop browser pane with Family Fare store 6401 (50th and Grover,
Omaha, the resolver's `store_id`) selected, reading the page `h1` after waiting for it to appear. The pages load
through JavaScript: a plain fetch returned the site shell with no product (the gr-17 `unrendered` cause), so a plain
fetch was not used to judge any page.

Diagnostic re-run (not the measured run): a scratch copy of the Family Fare resolver whose only change is that
`catch { }` prints the exception, run once with `-OutDir` pointing at a scratch folder.

## Results per store

Totals come from `design/MEASURE-chip-resolvers-2026-10.jsonl` (157 rows, one per chip).

| Store | Resolver | Chips | Resolved | Unresolved | Errors seen | Hand check (right / wrong / unchecked) |
|---|---|---|---|---|---|---|
| Family Fare | `resolve-familyfare-urls.ps1` | 65 | 17 of 65 (26%) | 48 | 0 printed; 38 of 47 misses were HTTP 400 in the diagnostic re-run | 15 / 2 / 0 of 17 |
| Hy-Vee | `resolve-chips-hyvee.ps1` | 41 | 0 of 41 (0%) | 41 | 0 | none to check (0 resolved) |
| Aldi | none | 28 | not run | 28 | n/a | n/a |
| Fareway | none | 23 | not run | 23 | n/a | n/a |

### Family Fare hand check (all 17 resolved, so no sample was drawn)

| # | Chip id | Board item | Page heading opened | vs commodity | Opens board item? |
|---|---|---|---|---|---|
| 1 | ground-beef-8020 | Fresh 80% Lean Ground Beef Value Pack | Standard Pride 80%/20% 100% Pure Ground Beef 48 Oz Discount Limit 2 | right | no |
| 2 | avocados | Hass Avocados, Small | Marzetti Dressed Avocado Green Goddess | **wrong** (salad dressing) | no |
| 3 | fresh-basil | Local Roots Organic Basil | Local Roots Organic Basil | right | yes |
| 4 | blueberries | Flavor Ripe Blueberries 18 Oz | Fresh Blueberries | right | no |
| 5 | butter | Land O Lakes Butter, Unsalted 4 Ea | Our Family Butter, Salted 4 Ea | right | no |
| 6 | butternut-squash | Butternut Squash | Butternut Squash | right | yes |
| 7 | cantaloupe | Organic Melon, Cantaloupe, Small | Fresh & Finest Cantaloupe Cubes | **wrong** (18 oz cut fruit, priced as $5.00/18 "each") | no |
| 8 | chuck-roast | Fresh Beef Chuck Roast, Boneless | Fresh Beef Chuck Roast, Boneless | right | yes |
| 9 | coffee | Maxwell House Coffee, Decaf Original, Medium, Ground 29.3 Oz | Maxwell House Original Roast Ground Coffee C | right | no |
| 10 | coffee-pods | Gevalia ... K Cup Pods 10 Ea | Eight O'clock Coffee K Cup Pods ... Value Pack 32 Ea | right | no |
| 11 | fresh-rosemary | Fresh Og Rosemary | Fresh Og Rosemary | right | yes |
| 12 | mozzarella-cheese | Our Family Natural Part Skim Mozzarella Shredded Cheese 32 Oz | same | right | yes |
| 13 | sriracha | Tabasco Sriracha Hot Sauce 11 Oz | Huy Fong Hot Sriracha Chili Sauce 28 Oz | right | no |
| 14 | almond-butter | Our Family Creamy Almond Butter | same | right | yes |
| 15 | bone-broth | Our Family Beef Bone Broth 32 Fl Oz | same | right | yes |
| 16 | protein-pasta | Creamette Protein Penne Pasta 14.5 Oz | Creamette Protein Rotini Pasta 14.5 Oz | right | no |
| 17 | boneless-pork-chops | Open Acres Boneless Rib Eye Pork Chops Value Pack | Fresh Pork Sirloin Chops, Boneless | right (a judgement: a boneless chop, a different cut) | no |

Derived from the rows: right 15 of 17, wrong 2 of 17, unchecked 0 of 17. Opens the board item: 7 of 17.

## Verdicts

- **`resolve-familyfare-urls.ps1`: NOT MET.** Resolved 17 of 65 (26%) against a 50% bar, and 2 wrong links among 17
  checked against a bar of zero. It fails on both counts, so fixing either one alone does not change the verdict.
- **`resolve-chips-hyvee.ps1`: NOT MET.** Resolved 0 of 41 (0%).

Aldi and Fareway have no resolver; they stay with the browser task, which is W8 step 3.

## Why each one misses (findings for whoever picks this up)

1. **Family Fare: the misses are mostly an API block, not "does not carry".** In the diagnostic re-run, 38 consecutive
   chips (frosting through traditional-pasta-sauce) got `HTTP 400 Bad Request` and recovered after. The shipped
   resolver's `catch { }` turns each one into `MISS ... no valid match`. A standalone probe after run 1 got HTTP 200
   with rows for four of those same queries (large eggs 8 items, sour cream 25, strawberries 25, spaghetti 25). So
   the term is not the cause, and it looks like rate limiting at the resolver's 350 ms spacing. `carriage.json`
   evidence elsewhere in the estate spaces Freshop calls 4 s apart. The two runs differed by one chip
   (frozen-green-beans: MISS in run 1, OK in the re-run), so 17 vs 18 is noise at n=2 runs.
   **The resolver also writes all 48 misses, blocked ones included, to `out\ff-notcarry.json` as "Does not carry"
   candidates. That breaks gr-17 (UNCHECKED IS NEVER NOT-CARRIED).** Of the 27 chips that got an answer, 17 resolved
   (63%), but that figure is from one run and is not the bar's denominator.
2. **Family Fare: it picks the CHEAPEST product that passes the commodity rules, not the board item.** That is how
   both wrong links arose. The avocado dressing passed the avocados rules, and the 18 oz cubes beat a whole melon
   because `PerUnit` for unit `each` divides the price by the "18" in "18 oz". It is also why only 7 of 17 links open
   the product the board prices.
3. **Hy-Vee: 0 of 41 is by construction.** Every worklist Hy-Vee chip is an ad cell whose size lives inside the item
   text ("Hy-Vee flour, 5 lb., $2.88") and whose board `size` is empty (41 of 41). The resolver's SIZE-FIRST gate
   needs `Get-LinkPerUnit` on the chip, which returns null for all 41, so every candidate is dropped before name
   matching ("best 0%"). The API was not blind: a probe at storeId 1466 returned 40 results for flour, almonds and
   bacon. The 2026-09-05 `chips-hyvee.json` already carried empty sizes on its ad rows, so the gap predates the
   adapter.

## Not done, and why

- Nothing wired (W8 step 2 is conditional on MET; neither is).
- No resolver was changed. The diagnostic copy lived in the scratch clone only.
- Aldi and Fareway were not measured: no resolver exists.

## For wiring later (if a resolver is fixed and re-measured)

The Family Fare resolver writes two TRACKED paths: `grocery/out/url-inputs/store-ff-urls.json` and
`grocery/out/ff-notcarry.json` (`git ls-files` lists both, and the scratch clone showed both modified after the run).
The Hy-Vee resolver's input `grocery/out/url-inputs/chips-hyvee.json` is tracked too; its `-Apply` output
`store-hyvee-nolink-urls.json` is not. All of them are written with `Set-Content -Encoding UTF8` (BOM, CRLF under PS
5.1), while og-39 says a tracked file written under PS 5.1 is written LF. A chain step that rewrites them daily would
need that fixed first, and would put `ff-notcarry.json`'s blocked-as-not-carried rows (finding 1) into git.
