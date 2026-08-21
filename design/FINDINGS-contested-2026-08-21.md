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
