# PLAN: link a Hy-Vee flyer line to the product it prices, so the store can verify it (2026-09-26)

**Status: PLAN ONLY, for Brad to read and edit before anything is built.** Ruled in chat on 2026-09-26 on
`design/ready-for-brad/Q-ab11be-flyer-line-road.md`: "Build link" (option B), with option A (the lines stay published
and the verifier names them unverifiable) in force until the link is live and measured.

## The problem, in one paragraph

A Hy-Vee sale cell is a flyer LINE, not a product: `"Simply juice, 46 or 52 fl. oz., $4.98"` (valid 2026-08-31 to
2026-09-27) is a product family, a size range and a price in one string. `Test-TcFlyerLineNamesNoProduct`
(`grocery/flag-verify-lib.ps1`) marks such a claim unverifiable by construction, because no product read carries that
name and re-reading the flyer re-runs the same parser. On `comparison-2026-09-23.json` that was 56 of the 151 ad-read
sale cells: Hy-Vee 53 of 53 and Fareway 3 of 37 (the ruling file's count; the detector header says 155, 4 unexplained).
The flyer has mis-parsed before (the 2026-09-07 laundry pods), and nothing after publish can catch the next one.

## Knowledge consulted

Searched "flyer line product link verify" (skills, memory, rules). Used:
- `grocery/flag-verify-lib.ps1` header: a flag is "a QUESTION put to the store", with verdicts match / wrong-price /
  wrong-product / could-not-look, and "A SALE THAT HAS ENDED re-reads at the regular price. That can never CONFIRM a sale
  price, and cannot condemn one either ... so a sale claim is compared on price only when the store's read falls inside
  the claim's own ad window." The linker only supplies the product; this verdict logic is reused unchanged.
- `grocery/ad-match-lib.ps1` header: "THE PRICE IS THE DISAMBIGUATOR ... A shared price plus ONE shared distinctive word
  is far stronger evidence than two shared words alone." The matching rule below starts from this, in the other
  direction (line to product instead of cell to line).
- `grocery/pull-regular-hyvee.ps1` header: the Aisles Online GraphQL (persisted query, `storeId` a request variable, no
  session) returns `storeProducts.price` (what the store charges today), `basePrice` (regular), `onSale`,
  `priceMultiple`, and `retailItems.tagPrice`; "Hy-Vee's own `product.size` cannot be trusted" ("12 fl oz Cans" for a
  12-pack). So the link keys on price and identity, never on Hy-Vee's size field alone.
- `grocery/discover-hyvee.ps1` header: search exists (`HV-Search`: `searchTerm`, `storeId`, `pageSize`), carries NO
  category field, and "passing that facet back as a `searchFilters` constraint is SILENTLY IGNORED". So a search hit is
  a candidate, never an identity, and "an unreviewed discovery path is a machine for installing wrong cheapest prices".
- memory `grocery-method-hyvee`: Omaha #02 (storeId 1466 plus locationId) since 2026-08-21, and since 2026-09-10 the ad
  flyer keys on that storeId (proven). The read and the flyer are the same store.
- `.claude/rules/grocery.md`: "A BAD CELL QUARANTINES ITSELF" (a wrong-price verdict withholds the cell: this is the
  risk), and "EVERY PRICE IS FETCHED FROM AN OMAHA STORE'S AD OR WEBSITE BY THE PIPELINE".
- `.claude/rules/measurement.md`: write the bar before the run, one row per case per arm, a matcher that abstains is
  scored on what it skipped, record the case at the moment it fails. Exemplar `sidecar/matcher_eval.py`.

## The risk this plan is shaped around

The ruling file names it: **a bad link flags a real sale as wrong and withholds it.** A wrong product read inside the
window (the 46 oz Simply when the line priced the 52 oz, or a different Simply flavour at a different price) gives
`wrong-price`, the cell quarantines, and a real Hy-Vee sale disappears from the board. That is a FALSE WRONG-PRICE, and
it costs readers a real deal. So the design has one rule above all: **a link that is not proved stays unlinked, and an
unlinked line stays under A (unverifiable, published).** Abstaining is always safe; a wrong link is not.

## 1. How a flyer line maps to Aisles Online product ids

Inputs per line (all already captured): the line text, `ad_from`, `ad_to`, the store (Hy-Vee, storeId 1466), and the
commodity the board assigned the cell to.

1. **Parse the line** into brand-and-family words, zero or more stated sizes (`46 or 52 fl. oz.`, `10 to 14.75 oz.`),
   and the price (`$4.98`, or an N-for-$X multibuy). A line whose price does not parse is not linked.
2. **Candidates:** `HV-Search` on the family words at storeId 1466, plus every Hy-Vee product id the board already
   holds for that commodity (`hyvee-regular-*.json`, `product-urls.json`). Search only proposes; it never decides.
3. **Read each candidate once inside the window** (the day the ad is ingested, which is inside the window by
   construction), through the same GraphQL document `pull-regular-hyvee.ps1` sends: `storeProducts.price`,
   `basePrice`, `onSale`, `priceMultiple`, `tagPrice`, name, size. This is a store read, not a flyer re-read, so it is
   independent evidence.
4. **Record every candidate and its read**, linked or not, in `grocery/out/hyvee/flyer-links-<date>.jsonl`, one row per
   (line, candidate). The rejected candidates are the corpus's negative cases.

## 2. The matching rule (a candidate is LINKED only when all four hold)

1. **Price proof.** The candidate reads `onSale = true` inside the window AND its `storeProducts.price` (per-item after
   `priceMultiple`, as the puller already reconciles) equals the line's price to the cent. Not "close": equal.
2. **Identity.** Every brand-and-family word of the line appears in the candidate's name (after the stop list
   `ad-match-lib` already uses), and the commodity's own identity rule (`Test-TcStoreNameIdentity`) does not refuse
   the name.
3. **Size inside the stated set.** When the line states sizes, the candidate's size, as read by OUR parser from its
   name (never Hy-Vee's size field alone), is one of them, or inside a stated range.
4. **Unique proof for the cell.** The cell prices ONE size. If candidates at more than one size pass 1 to 3 at the same
   price (the "46 or 52" case), the link is kept only when the cell's own published size is among them; the linked
   product is the one AT the cell's size. If none is at the cell's size, or two different products are at it with
   different prices, the line is not linked.

Anything else: **unlinked, reason recorded** (no candidate, price differs, onSale false, identity refused, size outside
the line, ambiguous). An unlinked line keeps today's A behaviour exactly.

What the link then does: `Find-TcStoreReread` gets a product road for the linked line (its product id), and the
existing verdict logic runs on the store's later in-window reads. **Nothing in the verdict logic changes.**

## 3. The acceptance bar, stated before any run

Measured on a hand-labelled corpus: the 53 Hy-Vee flyer-line cells on the newest board at the time of the run, plus the
3 Fareway lines kept aside (Fareway has a different product road and is out of scope for this plan's first cut). Each
row: the line, the product id Brad or a reviewer says it prices (or `none`, meaning no single product proves it), and a
`source` naming who labelled it and from what (the Hy-Vee product page, read in window). Labels are written BEFORE the
linker runs on the corpus, into `grocery/hyvee/flyer-link-gold.jsonl`.

Units are LINKS over the 53 lines:

- **Precision bar: 0 wrong links out of the links made, with at least 20 links made.** A wrong link is one whose
  product id differs from the label, or a link on a line labelled `none`. One wrong link fails the bar, because one
  wrong link is one real sale withheld from readers. Written as: `wrong_links == 0 and links_made >= 20`.
- **Coverage is reported beside it, never folded in:** `links_made of 53`. The floor of 20 of 53 (38%) is there so an
  arm that abstains on everything cannot pass; it is the first plausible number, nothing else was tried.
- **False-wrong-price rehearsal:** replay every linked line through `Resolve-TcRereadVerdict` against the in-window
  reads already captured. Bar: **0 `wrong-price` verdicts on lines whose label says the link is right.** Any such
  verdict is a false wrong-price and blocks rollout whatever the precision number says.

If the bar is missed, the failed rows are added to the corpus as recorded failures, the rule is changed, and the next
run states how many variants of the rule have been tried (a number that moved is not a number that improved).

## 4. How a mismatch is scored

One row per (line, arm) in `grocery/hyvee/flyer-link-cases.jsonl`: line, label, linked id or `none`, reason, verdict
on replay. Each row falls in exactly one cell:

| Label \ Linker | linked, same id | linked, other id | not linked |
|---|---|---|---|
| a product | correct link | **WRONG LINK** (counts against the bar) | abstain (costs coverage only) |
| `none` | n/a | **WRONG LINK** | correct abstain |

Totals are derived from the rows, never kept separately. A wrong link is recorded at the moment it is found, with the
candidate's read, so the fixture set grows from real failures.

## 5. Rollout

1. **Build the linker** in `grocery/hyvee-flyer-link-lib.ps1` with a self-test: MUST FIRE the "46 or 52 fl. oz."
   line links only at the cell's size; MUST NOT FIRE a candidate one cent off, a candidate with `onSale` false, a
   candidate whose name drops a family word; CLEAN TWIN a single-size line with one exact candidate still links.
   A case AT the price bar (equal to the cent) and one a cent PAST it.
2. **Shadow mode, no board effect.** The ad ingest writes the link file daily; the verifier reads it but a linked
   line's verdict is written to the ledger as `shadow`, never quarantining, never paging. Run for one full Hy-Vee ad
   cycle (at least 7 days), and label the corpus meanwhile.
3. **Measure against the bar** (section 3). Report links made of 53, wrong links, and false wrong-price verdicts, with
   the harness blob and the corpus fingerprint.
4. **Brad rules on the result** (a ready-for-brad file). Only then does a linked line's verdict go live: wrong-price on
   a linked line quarantines like any other cell. Unlinked lines stay under A.
5. **Kill switch:** one flag in `stores.json` -> Hy-Vee (`flyer_link: shadow | live | off`), so a bad day returns every
   line to A without a code change.

## What this plan does not do

- No change to the flyer parser, the ad window, or any published price.
- No Fareway lines (3 of 56); they need Fareway's own product road and can follow the same shape.
- Nothing publishes a price off the link: the link only lets the store's own read VERIFY the flyer price.

## Open questions for Brad

1. Is 0 wrong links over at least 20 the right bar, or do you want a larger minimum before going live?
2. Who labels the 53: you, or a session reading each Hy-Vee product page in window with the evidence recorded?

## Ruling (Brad, in chat, 2026-09-26)

"Yes, build to that bar"

Build in SHADOW mode. Open question 1 answered: the bar stands as written. Open question 2 answered: the orchestrator labels the 53-line answer set (`labels: proposed`) and Brad reviews the labels.

## Ruling (Brad, in chat, 2026-09-26): variant 2 and the labels

On the variant question (Q-2026-09-26-flyer-link-labels, item 2): **"Both loosenings"**. (a) Map Hy-Vee's abbreviations
(Ckn, BC, Qkr, ...) to brand and family words, and (b) accept any flavour in a same-price set. Re-score against the SAME
bar; the linker stays in shadow.

On the labels (item 1): **"Accept sets"**. The 13 set-shaped labels in `grocery/hyvee/flyer-link-gold.jsonl` are accepted as
the label shape.

Result (`design/MEASURE-flyer-line-link-2026-09-26.md`, Variant 2): variants tried 2, bar unchanged, **18 of 53 linked,
0 wrong of 18, 0 false wrong-price on replay. The bar is MISSED on coverage (18 is under 20).** The abbreviation map was
derived from the same evidence it is scored on, so it is not held out. Step 2's shadow period now runs daily as the
`check-ad-cycles` fan-out lane `hyvee-flyer-link` (variant 2); `stores.json` stays `shadow` and nothing reads the file to
change a verdict. Step 4 (going live) still waits on a ruling over a result that meets the bar.
