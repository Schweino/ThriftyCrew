# Which flyer linker should give flyer prices their "See item" link? (2026-09-27)

**The issue.** Your D1 ruling today says a flyer price must carry a link to its product, found by the system. Two
pieces of work now answer "which product is this flyer line for?":

- **The shadow linker** (`grocery/hyvee-flyer-link.ps1`, your plan of 2026-09-26). Hy-Vee only. It exists to let the
  price checker verify flyer prices, and it is in shadow, waiting on its bar: 0 wrong links out of at least 20. On its
  hand-checked set of 53 lines it links 18, with 0 wrong.
- **The new resolver** built today for the link plan (`resolve-flyer-links.ps1`, parked on a branch, not live). Hy-Vee
  and Family Fare. On the same 53 lines it links 23 but gets 2 wrong: a frosting at its everyday price rather than on
  sale, and a peanut variety our identity rule refuses. The shadow linker checks both of those things and the new one
  does not.

**Why it matters.** Running both would give two answers to one question, and every wrong "See item" link we have
ever shipped came from two records disagreeing. One of them has to be the road.

**Recommendation: one linker, the shadow one, extended.** Give it Family Fare (the new resolver's Freshop part carries
over), have the link plan read its output for the page, and go live on the bar you already set. Flyer prices keep
today's weekly-ad button until then. The new resolver's two misses are the reason: the shadow linker already knows
what it would have to learn.

The alternative is to make the new resolver the road, fix its two misses and re-score it on the same set. That is
faster to show links on the page, but it builds a second copy of rules that already exist.

Detail: `design/PLAN-link-rides-with-price-2026-09-27.md`, item L1b.
