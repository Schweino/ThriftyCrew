# The Aldi pack basis: which reading of a multipack card is right, and how often

2026-09-19. Behind `grocery/build-aldi-regular.ps1`'s `Resolve-PackBasis`, which replaced the old
`Get-Size` rule 1b.

## The question

When an Aldi storefront row's NAME states a pack count N greater than 1 and the tile's card states one
bare measure S, the card is either

* **reading A**, the size of ONE unit, so the pack total is N x S, or
* **reading B**, the PACK TOTAL, so the pack total is S.

The two readings differ by a factor of N in the per-unit price, and reading a total as a unit is the
CHEAP direction, which is the direction that crowns a phantom cheapest. The old rule took reading A
whenever the name carried a pack count, with no test.

## The acceptance bar, written before the run

Stated in the metric's own units, before any count was taken:

> Adopt a rule that reads the card only if, over the captures on this box, it is right in every case
> where it commits to a reading. A rule that is right "usually" is not adopted, because the failures
> are four to forty times too cheap and land inside a sanity band often enough to be crowned. Where no
> reading can be proved, emit no size: a missing cell falls through to a product we can price, and a
> four-times-cheap cell wins.

## The harness, and what it read

**Harness and commit.** A two-arm driver over `grocery/build-aldi-regular.ps1`, run 2026-09-19 against
base commit `87968de7a24a7533051d6469b53a116126d161b6`, with the arms pinned by blob below.

Two arms of one script run out of process. The subject is `grocery/build-aldi-regular.ps1` itself,
dot-sourced, so each arm drives the production `Read-AldiCapture` and `Invoke-Build` rather than a copy
of their logic. The arm script walks every `grocery/out/captures/aldi-capture-*.csv`, builds each one
with `-WaiveMissingStoreLine` (several pre-date the `#tc-store` line), and writes ONE LINE PER BUILT ROW
and one per reject, keyed on capture date and item, so the arms compare case by case rather than by
totals. It is a scratch harness and stays described rather than committed: the question it answers about
the CODE is now held by this file's own `-SelfTest` fixtures, which can go red, and the question it
answers about ALDI needs a fresh live read rather than a replay.

* arm OLD, `grocery/build-aldi-regular.ps1` at blob `fbb33b3ea68088e72cdf03385858a12260a445f5`
* arm NEW, the same file at blob `fed15c41b1469274a2b96f546b752616b1e46905`
* base commit for both, `87968de7a24a7533051d6469b53a116126d161b6`
* inputs, the 22 `aldi-capture-*.csv` on this box on 2026-09-19, 24,262 records. The set hashes to
  `6614294e301197fd7cd11138f5523063ca9c6d99eb0b7075cf0e648c1fade9a2` (sha256 of the concatenated
  per-file sha256 listing). The captures are gitignored, so this fingerprint is the only thing that can
  say another run read the same bytes.
* live reads of aldi.us on 2026-09-19, store ALDI - OLA 42 - Omaha, In-Store.

Blobs rather than commit ids because `ops/push-main.ps1` rebases before it pushes, so the commit this
was measured at is not the commit that lands.

## What the capture set could and could not say

**Aldi's own per-unit rate is not reachable from a capture.** The `unit` column is populated on 0 of the
30 rows the old rule fires on. Checked live the same day: the search CARD carries no rate, and the rate
appears only on the product PAGE, which the sweep never opens. Hot Pockets Pepperoni Pizza 4 Pack reads
`18 oz | $0.26/oz` on its page, and $4.65 / 18 = $0.258, so the page settles that row outright. Idea (b)
in the brief is therefore correct and out of reach until the sweep fetches product pages. It is the
cheapest oracle available and it is worth its own item.

**Two thirds of the evidence is about our own extractor, not about Aldi.** No capture before 2026-08-25
carries a single `N x M` card: 0 in 5,542 records across 08-05, 08-15 and 08-22, against 301 in the 19
captures after the committed search agent landed. So a bare card size in an old capture may be a
TRUNCATED `N x M`, and 20 of the 30 rows say nothing about what Aldi printed. The live check confirms
this from the other end: `Puraqua Purified Water, 24 pack` cards `24 x 16.9 fl oz` today, and the
2026-08-15 capture recorded a bare `16.9 fl oz` for that exact product at that exact price.

**The 10 rows the modern extractor produced are 4 distinct cases, and they split 1 against 3.**

| case | rows | truth | which reading |
|---|---|---|---|
| `12 pack apple squeezies`, card 3.2 oz | 4 | total 38.4 oz | A, the card was one unit |
| `12 pack apple squeezies`, card 38.4 oz | 1 | total 38.4 oz | B, the card was the total |
| `hot pockets hot pockets pep 4 pack 18 oz`, card 18 oz | 4 | 18 oz at $0.26/oz, from Aldi's page | B |
| `summit mai tai mocktails 4pk 12 fl oz`, card 48 fl oz | 1 | 48 fl oz, and the name says 12 | B |

The first two rows are the SAME product id, 63924817, at the SAME price on different days, so no rule
that reads the card alone can be right for both. Aldi is inconsistent between siblings in one capture as
well: on 2026-08-15 `Lunch Buddies Fruit Bowls Mandarin Oranges ... 4 pack` carded 4 oz while
`Lunch Buddies Pineapple Tidbits ... 4 pack` carded 16 oz, same $2.19, same pack count.

**So idea (a) was measured and rejected rather than tuned.** Dividing the card by the count and asking
whether the result looks single-serve does separate these cases, at a bar somewhere between 2.8 and 3.2
oz. Four distinct cases cannot establish that bar, nothing rules out instability either side of it, and
a bar chosen after seeing the numbers is a description of a decision already taken. It would also be a
hard-coded band, which this estate forbids for exactly this reason.

**Live corroboration, one search page, 2026-09-19.** On a single `lunch buddies fruit` result page Aldi
rendered both conventions at once: `Aldi Pears Fruit Bowl in 100% Juice, 4 pack` 16 oz, `Aldi Pineapple
Tidbits in 100% Fruit Juice, 4 pack` 16 oz and `Aldi Cherry Mixed Fruit Cups - 4 Count` 16 oz as pack
totals, beside `Lunch Buddies Peach Fruit Cups in Juice` `4 x 4 oz` and `Lunch Buddies Strawberry
Applesauce Cups, 6 count` `6 x 4 oz` in multiplication form. The bare form is the total far more often
than not, and `12 pack apple squeezies` is the standing counterexample that stops that being a rule.

## The rule adopted

Resolve the basis by proof or not at all. The only proof a row carries is the NAME stating a size of its
own in the same unit whose arithmetic settles which reading is live:

* **P1**, name size = N x card, so the card is ONE UNIT. `6 PK 13.5 OZ` with card 2.25 oz, 13.5 = 6 x 2.25.
* **P2**, card = N x name size, so the card is the TOTAL. `4pk 12 fl oz` with card 48 fl oz, 48 = 4 x 12.

They cannot both hold, since P1 with P2 needs S = N squared times S. A name size EQUAL to the card proves
nothing and both readings of that shape are real, which is why `gatorade thirst quencher 18 pack 12 fl oz`
carded 12 fl oz (216 fl oz of drink) and `hot pockets hot pockets pep 4 pack 18 oz` carded 18 oz (18 oz of
sandwich) are both refused. With no proof the row gets no size and is rejected naming this reason rather
than `no size`. The tolerance is 2% relative, which cannot confuse two readings that stand a factor of
N >= 2 apart.

## What changed, counted

Over the 22 captures, arms compared row by row:

* built rows **12,316 old, 12,292 new**. **25 rows change, 0.20%.**
* **24 rows that were built are now rejected**, every one with the new reason `pack basis unproved: ...`.
  19 of the 24 are from pre-2026-08-25 captures that will never be rebuilt.
* **1 row has its size corrected**: `Summit Mai Tai Mocktails 4pk 12 FL OZ`, `4 pk 48 fl oz` (192 fl oz,
  four times too cheap) to `48 fl oz`.
* **0 rows appear.**
* rows carrying a multiplying `N pk M` size: **243 old, 218 new, and all 218 are byte-identical**. Nothing
  was gained, so the card's own `N x M` path is untouched.

**The named known-good multipacks do not regress.** `Gatorade Thirst Quencher 18 Pack 12 FL OZ` is in the
captures twice, once with card `18 x 12 fl oz` and once with no card at all, and both still build
`18 pk 12 fl oz`. It never appears with the truncated bare `12 fl oz` card that the old fixture used, and
that fixture form cannot occur after 2026-08-25. The Maruchan `6 PK 13.5 OZ` shape is P1 and still emits
`6 pk 2.25 oz`. The 2026-09-09 `12 x 12 fl oz` card form is rule 1b-ii and was not touched.

None of the 25 changed rows is on `grocery/out/comparison-2026-09-17.json`, so this was a latent exposure
rather than a live wrong number, which is the same thing the band floor said about the pineapple.

## Found, measured, and deliberately NOT fixed

`Get-Size` rule 4 reads a pack stated in the NAME with no card size, and multiplies it the same way rule
1b used to. **It has the same ambiguity and one live wrong row**: `Puraqua Water 40pk 676 FL OZ` builds
`40 pk 676 fl oz`, which is 27,040 fl oz, because 676 is the pack total (40 x 16.9) and rule 4 multiplies
it again. 49 built rows over 25 distinct products take their size from the name this way, and most are
demonstrably right (`Gatorade Thirst Quencher 18 Pack 12 FL OZ`, the Friendly Farms 4-packs, the 8-packs
of juice boxes), because a name usually does state the per-unit size.

No proof exists inside those rows: the name states N and one size, and nothing else. Extending the
refusal there would drop 49 rows to fix 1, on no evidence, so it is recorded here rather than guessed at.
The honest fixes are the product-page rate above, or a name-shape rule measured on its own evidence.

Re-read at harness blob 7855258779d973df581da94bc4f8b0a0ace889a8 (grocery/build-aldi-regular.ps1): Resolve-PackBasis, the arithmetic-proof rule and every count above are untouched by the one later change (queue 2026-09-22-20fecf), which only records the build's ingest shape after the rejects file is written.
