# Operational / architectural findings — contested-row work, 2026-08-21

Brad asked me to log anything discovered along the way that would make the system
better, faster, or more accurate. Running log. Each entry says what was measured,
not what was assumed.

Status key: **DONE** shipped · **PROPOSED** not built · **WATCH** needs evidence

---

## 1. Guard ordering was convention, not invariant — DONE

`audit-tile-integrity` does not compute its WRONG-PRODUCT verdicts. It reads them
from `out\name-drift.json`. Any `compare-deals` run rewrites `comparison-*.json`
and any link rewrite touches `product-urls.json`, so both routinely become newer
than the flags being used to judge them.

Both pipelines already do the right thing — `weekly-post-capture.ps1:155` and
`check-ad-cycles.ps1:1099` each run `audit-name-drift` immediately before
`guards.ps1`, and `weekly-post-capture.ps1:146` documents why. But nothing
*enforced* it. Anyone running the audits by hand, in any other order, got a
verdict about the past.

Measured: after re-deriving 52 links, the audit failed 7 tiles whose board row
and link were by then character-for-character identical.

That is the harmless direction. The harmful one is the same bug sign-flipped:
point a link at the wrong product while the flags are stale, no flag is found,
the tile passes — a false green on the gate enforcing "price and item name must
match the link 100%".

Now a staleness assertion, HELD not warned, with no `-Force` path.

## 2. The contested list is a standing backlog nobody works — WATCH

`audit-match-contested.ps1` already finds every row whose owner is decided by
array order in `commodities.json`. `audit-match-soundness` reports the count on
every publish. It read **710 contested** the day this log started.

All three wrong-price bugs fixed on 2026-08-20/21 — whole cloves at $11.92/oz,
plain milk swallowing the cheap chocolate gallon, `oranges` claiming OJ — were
already in that pool. The detection existed. The information was never missing.
Nothing turns it into work.

A number that only ever gets printed is not a control.

## 3. Restoring a source file is not restoring the system — DONE

Building `promote_aliases --gated` surfaced this, and it generalises well beyond
that script.

The gate promotes aliases, rebuilds the board, runs guards, and on failure puts
`commodities.json` back. That felt like a clean rollback. It is not: the board
(`comparison-*.json`) and the drift flags are DERIVED from the catalog, and the
last thing a failing round does is rebuild them from the very aliases being
withdrawn. Restoring only the source left a tree where the catalog was clean and
everything computed from it was not.

Observed exactly once, immediately: the next run refused to start, reporting a
red baseline that named two aliases no longer present in any file on disk.

Rollback now means restore-and-rebuild, on one path, in a `finally`, covering
exceptions and Ctrl-C. Anything in this estate that edits a source input and can
bail out has the same obligation — `commodities.json`, `product-urls.json`,
`category-excludes.json` all have derived artefacts downstream of them.

## 4. A rollback that only fires on catastrophe is not a rollback — DONE

Same script, found by reading the code the test made me re-read. The original
`finally` restored only when the catalog had been left *missing or empty*, so
all three ordinary failure exits printed "tree restored" while leaving the
failing round's edits in place. The message was true only in the case that never
happens.

Now a single `promoted_ok` flag: green keeps its edits, every other exit
restores. Worth grepping for elsewhere — "restore only if the file looks
destroyed" is a tempting shape, and it protects against the rarest failure while
ignoring the common one.

## 5. The must-fire fixture earned its keep — WATCH

Both of the above were found by deliberately clearing two known-bad holds and
checking the gate rediscovered them, rather than by running the gate on a batch
where it would pass. A gate tested only on the happy path proves nothing; this
one had two bugs that a passing run would never have exposed, and one of them
silently discarded verdicts it had just spent two guard cycles earning.

`test-guards.ps1` / `run-test-guards-weekly.ps1` already apply this idea to
`guards.ps1`. Nothing applies it to the newer Python gates.

## 6. Three copies of the matcher, no measurable divergence — WATCH, not urgent

`Match-Category` — the function deciding which commodity owns a product name —
is defined three times: `compare-deals.ps1:1326` (the engine),
`audit-household-in-food.ps1:26`, and `validate-fills.ps1:33`. The two auditors
are byte-identical to each other and different from the engine.

The difference is real. The engine runs `Get-MatchTexts`, testing includes
against TWO strings — the raw lowercased name and a variant with Sam's
", priced per pound" suffix stripped and "and" collapsed to a space. The
auditors test the raw name only. So in principle the engine can match a product
the auditors think matches nothing, and `audit-household-in-food` is guard 2 in
`guards.ps1:249` — a cleaning product landing in an edible commodity would go
unreported.

I expected this to be a live false-negative. It is not. Measured across all
**36,661 distinct product names** in `out\regular`: **0 disagreements**. Every
product the engine assigns, the auditors assign identically. The variant text
never changes an outcome on the current corpus.

So this is latent, not active, and I am not going to dress it up as more. What
makes it worth an entry is that nothing tests it: change `Get-MatchTexts` and
the auditors silently start describing a different engine, with no failing test
anywhere. The check that proved it benign took about 90 seconds to run and is
mechanical — engine matcher vs auditor matcher over every distinct name, assert
zero disagreements. As a weekly assertion it converts a silent future break into
a caught one.

`audit-match-contested` and `audit-match-soundness` do NOT have this problem:
they regex-scrape the engine's own source (`compare-deals.ps1:895`) rather than
keeping a copy. Ugly, but correct by construction, and the estate already knows
it — that scrape is guarded.

## 7. The 663-row contested backlog is really a 22-row backlog — DONE (method)

The number that makes this work look unaffordable is the wrong number.
`audit-match-contested` reports **663 contested rows**. Joining those against the
live board — keeping only rows where the WINNING commodity actually publishes
that product in a priced cell — leaves **22**. Everything else is a product that
never wins a cell anywhere, so its ownership is theoretical.

Written to `out\contested-live.json`. That join is the missing prioritisation
step: it turns "663 latent ambiguities" into a list a person can read in ten
minutes, ranked by whether a shopper can actually see the consequence.

Of the 22, nineteen resolve correctly on inspection (fresh green beans beating
canned, tahini beating sesame seeds, tuna-in-vegetable-oil beating vegetable
oil). One was a live wrong price. See #8.

## 8. A dog treat was the CHEAPEST beef jerky on the board — DONE

`beef-jerky` published **"Golden Rewards Chicken Flavor Premium Dry Jerky Treats
for All Dogs, 16 oz"** at $0.6231/oz as its crown — the cheapest beef jerky in
Omaha, and the number a shopper would act on, was dog food.

beef-jerky carries **ten** pet-exclusion patterns. Not one fired:

  `\bdog\b`                              name says "Dogs"  — plural
  `\bfor\s+dogs?\b`                      name says "for All Dogs" — a word between
  `\bfor\s+(?:dogs?|cats?|pets?)\b`      same
  `dog\s+(food|treats?|snacks?|chews?)`  name is "Jerky Treats for All Dogs"

This is the SAME defect as the cloves, the milk and the oranges: patterns that
assume adjacency and exact number. Fourth instance in two days. It is the
dominant bug class in this catalog and it is not a coincidence — the patterns
read like English, and English puts words between other words.

Fixed centrally in the `pet` class of `category-excludes.json` rather than on
beef-jerky, so every guarded commodity benefits:

    \bfor\s+(?:\w+\s+){0,3}(?<!hot\s)(?<!corn\s)(?<!chili\s)(?:dogs?|cats?|puppies|kittens)\b

The lookbehinds are not decoration. The first draft, without them, was measured
against all 36,487 distinct product names and caught one human food:
*"Castleberry's Hot Dog Chili Sauce ... Topping for Hot Dogs and Coney-Style
Franks"*. A bare `\bdogs?\b` token would additionally have destroyed hot-dogs
and corn-dogs outright. Measured final: +33 pet products caught, 0 human-food
false positives, 0 regressions.

Board effect: 2 cells, 1 crown. beef-jerky $0.6231 @ Walmart -> $0.998 @ Aldi.
The crown got MORE expensive, which is the point — a false bargain was removed.
Soundness also dropped **"Blue Buffalo Natural Puppy ... Food For Puppies"** out
of `brown-rice`, a second latent wrong price nobody had reported.

## 9. Every price move orphans its link, every time — PROPOSED

Four times in two days now: fix a match, the price moves, and `tile-integrity`
immediately hard-fails because `product-urls.json` still pins the old product.
Cloves, chocolate milk, the 7-tile batch, beef-jerky. The remedy is always
identical — `derive-links-from-prices -Store <the one that moved> -Apply`.

The guard is doing its job; the workflow just has a manual step that is 100%
predictable from the diff. Anything that changes which PRODUCT a cell holds
should offer to re-derive that store's links, or at minimum name the exact
command with the store already filled in. Right now every fixer has to know to
do it, and the failure only appears one guard run later.

## 10. Blast radius measured on the wrong corpus — DONE

Every blast-radius check I ran on 2026-08-21 globbed `out\regular\*.json` only.
That is **36,487** names. The real corpus, once `out\sams`, `out\bakers`,
`out\fareway`, `out\extra` and `ads-*.json` are included, is **44,125** — the
partial view was missing 17% of the products the engine actually prices, and
Sam's Club almost entirely, because Sam's ships a `sams-deals-*.json` as well as
a regular file.

Caught by accident: a new pattern was measured as catching 3 products, but the
Sam's row it was written for was not among them. It was not in the corpus.

The shipped `pet` class change was re-verified against the full 44,125 — still
0 human-food false positives — so nothing bad went out. But the check that
proved it was weaker than it looked, which is the part worth fixing. Any
blast-radius measurement should read the same file set the engine reads, not a
convenient subset of it. Cached to `%TEMP%\corpus-names.json` for this session;
it belongs in a shared helper.

## 11. Excluding a product does not delete it — it re-homes it — DONE

Ruling 3 (serranos are not mild green chiles) was applied as an exclude on
`canned-green-chilies`. That freed the La Costena can, which promptly landed in
`serrano-peppers` — a FRESH, per-pound produce row — at $3.06/lb, and
tile-integrity caught it at 2.09x within one guard run.

An exclude is not a delete. First-match-wins means the product falls to the next
commodity whose patterns accept it, and that commodity may be a worse home than
the one it left. Every exclude needs the second question asked: not just "should
this row lose it" but "who gets it next".

Fixing that surfaced a pre-existing defect in the same row: `serrano-peppers`
was claiming **seven hot sauces and taco sauces**. Fresh-produce rows now
exclude sauce and fire-roasted forms.

And removing the serrano can from `canned-green-chilies` promoted the next
cheapest, which was **"Stokes Green Chile Stew with Pork and Potatoes"** — a
stew, crowned as the cheapest canned diced green chile. Behind it sat burritos,
refried beans, queso and an aioli: eleven products where "green chile" is a
FLAVOUR, not the contents. That row now excludes the carrier forms and reads
$0.2125/oz for Benita Chopped Green Chiles, which is what it always claimed to be.

Three defects, all revealed by one exclude. The exclusion was correct; what it
displaced was not.

## 12. A canned commodity priced by fresh fruit — OPEN

`mandarin-oranges` is labelled "Canned Mandarin Oranges" and its cheapest cell
is Aldi's **"Mandarin Oranges" 3 lb at $0.0706/oz** — a bag of fresh
clementines, roughly half the price per ounce of any real can on the row.

Not fixable by name pattern: the name is exactly "Mandarin Oranges" with no
form word to key on. The only tell is the size — a 3 lb sack is not a can. The
board already carries a size field and `audit-unit-basis-outlier` already
reasons about pack shape, so the machinery exists; the rule does not.

Left open deliberately. It needs a form-vs-size rule, not another regex, and
inventing one mid-session is how the last four patterns got written.

## 13. The adjacency class is now CLEAN on the live board — DONE

`graph/learning/lint_adjacency.py` sweeps every exclude pattern in the catalog
for the defect that shipped four wrong prices: a pattern written as adjacent
words, defeated by a name that separates or pluralises them. It checks against
the full 44,125-name corpus and reports only near-misses on products the
commodity ACTUALLY CLAIMS - an exclude missing something its commodity never
wanted is not a defect.

Result after the four fixes:

  704 near-misses total
   19 on a product the board publishes  -> all 19 read, ALL CORRECT BEHAVIOUR
   17 flagged as class-risk (pet / household / alcohol / supplement)
    0 of those on a live cell

The 19 live ones are things like `chili\s+beans` not firing on "Chili with
Beans" (which IS canned chili), `ground\s+mustard` not firing on "Stone Ground
Dijon" (which IS dijon), `corn\s+chips?` not firing on "Corn Tortilla Chips"
(which ARE tortilla chips). The pattern is supposed to miss those.

So: no remaining live instances of this class in the machine-checkable shape.
That is a result, not a null. It is also exactly the claim that needs a
must-fire test before anyone believes it, so:

  fixture   remove milk's \bchocolate\b exclude (the 2026-08-21 fix)
  ->        30 near-misses on milk, including "LALA Chocolate 1% Milk",
            "Nesquik Chocolate Low-fat Milk", "Horizon Organic Chocolate
            Low-Fat Milk" - the exact products that caused the original bug
  restore   0 near-misses. Clean twin.

Two limits, stated rather than hidden. It only reads patterns made of plain
words - anything with alternation or a character class is skipped rather than
guessed at, so `\bfor\s+(?:dogs?|cats?|pets?)\b` (one of the ten that failed on
the dog treat) is invisible to it. And single-letter literals are dropped as
noise after `\bd\s+batteries\b` near-missed every AA pack in the corpus.

Worth running after any catalog edit. Not a guard - it produces questions, and a
gate that fails on a question trains people to ignore it.

## 14. relink-drifted-cells: the forgotten step, automated — DONE (partially effective)

Four times in one day a match fix moved a price and orphaned its link, caught by
tile-integrity one guard run later, fixed by the identical command. That is a
mechanical consequence of the diff and should not depend on the fixer knowing.

`grocery/relink-drifted-cells.ps1` needs no before/after snapshot - a drifted
cell is self-evident: the board says the cell holds product X, product-urls.json
says its link opens Y. It groups those by store, re-derives ONLY those stores
(per store, never globally - derive-links-from-prices carries a scar about that),
and refreshes the name-drift flags afterwards, since tile-integrity reads them.

Honest result: **193 drifted tiles found, 7 repairable.** The other 186 are not
a bug in this tool - `derive-links-from-prices` can only write a link when the
capture row carries a product identity, and for Aldi and Fareway it usually does
not. Those links were resolved by SEARCH, not derived, which is exactly the
two-pipelines-for-one-fact problem `derive-links-from-prices.ps1` was written to
end. Ending it for the remaining stores means capture-side work, not link-side.

So the tool closes the loop for derived stores and reports honestly on the rest.
That is worth having, and worth not overselling.

## 15. The tolerated middle: 188 tiles whose link names a different variant — OPEN

`audit-name-drift` flags a link only when its name shares **zero** distinctive
tokens with the board's product name. Its own output says so: "some are just
brand differences". That conservatism is deliberate and load-bearing -
`generate-board-overrides` refuses to pin any cell name-drift flags, so a false
flag silently blocks a good pin.

The consequence is a gap between "shares no tokens" (flagged) and "identical"
(fine), and **188 priced tiles currently sit in it**:

    alfredo-sauce   Fareway   board Classico          link Ragu
    bbq-sauce       Fareway   board Original          link Honey
    bottled-water   Fareway   board Purified          link Natural Spring
    almond-milk     Aldi      board Vanilla           link Vanilla UNSWEETENED
    body-wash       Fareway   board Cocoa Butter+Shea link Ocean Breeze

Each shares enough words to pass, and each opens a different product than the
price describes. Against Brad's invariant - "the price and item name need to
match the link 100%" - these are violations that the guard reports as ACCURACY OK.

NOT unilaterally fixed. Tightening the threshold would flag the cosmetic cases
too ("Bananas" vs "Bananas Per LB", "Gala Apples" vs "Gala Apples, Bag") and
every false flag blocks a pin. The right fix is a similarity measure that
separates packaging noise from variant identity, and choosing that threshold is
a decision with a measurable board cost - it deserves its own pass, not a guess
at the end of one.
