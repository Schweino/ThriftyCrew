# Quality attributes, per subsystem, with priorities

**Why this exists (2026-09-09, backlog I83).** A grep for `ATAM`, `architecture tradeoff`,
`utility tree`, `quality attribute`, `Kruchten` and `Conway` across every `.ps1`, `.py` and `.md`
in this repo returned **zero matches**, and the same six terms are a clean no-match over 1,251
sections of the skills store. `docs/RUNTIME-MAP.md` is good and maps the runtimes and the git-bus,
but it states **no quality attribute, no priority and no scenario** - so nothing here could be
evaluated *against* one, and every design argument had to be re-derived from first principles.

**What is deliberately NOT here: a nine-step ATAM.** There is one person and no stakeholder groups
to convene. **What ports is the utility tree** - quality attributes, refined, with priorities, per
subsystem. **What does not port is the meeting.**

**How to read the priorities.** `H` / `M` / `L` is *importance to the business*. The second letter
is *difficulty to achieve here*. `H/H` is where the architecture is genuinely load-bearing and where
a change deserves an argument; `H/L` is something that matters and is already cheap, and the job
there is only to avoid breaking it.

---

## The one attribute that outranks the others

**CORRECTNESS OF A PUBLISHED NUMBER. `H/H`.** This is a live paid site, so a wrong number on a page
is a real cost to a real reader, and **understating is exactly as wrong as overstating**. Every other
attribute below can be traded against something; this one is the constraint the others are optimised
inside. Its scenarios are the ones with recorded costs: a per-unit price wrong by 3x from a bare
`each` basis, 22 paid recipes served free, a freezer tool telling a reader "16 months" when the data
said 10.

---

## `grocery/` - capture to board

| Attribute | Pri | The scenario it is really about | What holds it up today |
|---|---|---|---|
| Correctness of a published price | `H/H` | A shopper acts on a per-unit price that is wrong by an order of magnitude | `guards.ps1`, the engine-check invariant in the builders, `known-wrong.json` |
| **Refusal under uncertainty** | `H/M` | A store could not be read and the board records "not carried" | `UNCHECKED IS NEVER NOT-CARRIED`; BLIND and UNUSABLE as first-class verdicts |
| Freshness | `H/M` | A promo price outlives its window and is still sold | rollback TTL anchored to first detection, `audit-ad-status` |
| Throughput of a capture run | `M/M` | The 75-minute Walmart pull; a wall costs a whole day of a store | per-store pacing in `stores.json` with `evidence` required |
| Modifiability of the pricing math | `M/H` | A helper added to `Get-UnitPrice` breaks 12 scripts at run time | **nothing** - this is the estate's weakest seam, and it is backlog I82 |

**The tradeoff nobody had written down:** refusal-under-uncertainty is bought with throughput. Every
BLIND verdict is a cell that stays empty until someone looks, and the estate has consistently chosen
the empty cell. That is the right call and it should stay a conscious one.

## `meal-prep/` - recipes and costing

| Attribute | Pri | The scenario | What holds it up |
|---|---|---|---|
| Cost fidelity of a card | `H/H` | A recipe card quotes a batch cost the board does not support | spec-hash-versus-stamps dirty tracking, `sync-recipesdb-cost` before `propagate` |
| Fidelity to the source recipe | `H/M` | A recipe we sell is not the recipe we found | `recipe-source-qa`, the extractor's verbatim rule |
| Paywall correctness | `H/L` | Paid content served free, or free content locked | the split at `<!--TC-PAYWALL-->`, checked in **both** directions |
| Publish atomicity | `M/H` | A crash mid-wave loses the journal and the next publish refuses | per-slug journal writes |

**The headline metric's denominator is a ruling, not a default** (Brad, 2026-09-12, backlog I140).
`cost_per_serving` is what this estate prices on, `docs/HEADLINE-METRIC.md` is the ruling, and it
carries the cost-per-calorie argument against it with the answer. Relevant here because cost fidelity
above is an attribute of a number whose denominator was, until that date, nowhere stated.

## `graph/` - identity and learning

| Attribute | Pri | The scenario | What holds it up |
|---|---|---|---|
| Identity stability | `H/H` | A commodity id is retired and the graph silently shatters | `audit_graph_shape.py` cut-point report; the registrar |
| Reversibility of learning | `H/M` | A learned alias breaks the board on a day nobody is watching | `promote_aliases.py --gated`, `promotion-holds.json`, `--recheck-holds` |
| Durability | `H/M` | 126 MB of state, written nightly under WAL, no migration procedure | git commits it whole; **there is no rollback** - backlog I41 |
| Query cost | `L/M` | A fan-out from a Store returns 20,133 rows | the forward rule in `audit_graph_shape.py`; no cached degree - I74 |

## `ops/` and `lib/` - the machinery that keeps the rest honest

| Attribute | Pri | The scenario | What holds it up |
|---|---|---|---|
| **Detectability of a silent failure** | `H/H` | "No findings" and "died halfway" are the same bytes | `<NAME>-COMPLETE`, exit-3-is-not-a-pass, BLIND verdicts |
| Honesty of a clean report | `H/L` | An unsound detector's silence read as a proof | `SCOPE OF A CLEAN REPORT:` on every `ops/audit-*.ps1` |
| Gate credibility | `H/M` | A gate red on day one teaches people to ignore red | the ratchet pattern with a high-water mark |
| Speed of the gate | `M/M` | A gate slow enough that people stop running it | hermetic self-tests only; data-dependent audits in the daily chain |

## `site/`, `content/`, `worker/` - what a reader sees

| Attribute | Pri | The scenario | What holds it up |
|---|---|---|---|
| Correctness of reader-facing copy | `H/H` | A quantified claim with no quantity, or a stale tool verdict | the no-fabricated-numbers rule; **weakly held** - backlog I60 |
| Mobile legibility | `M/L` | A table crushed at 375px | the standing 375px check on any changed layout |
| Availability | `M/L` | The feed is stale or the Worker is down | `health-heartbeat`, the committed `board.json` |

---

## The one method piece worth stealing outright

**When two parties both have priorities, get both lists INDEPENDENTLY and diff them.** That is the
same instrument as this estate's case-NAME set diff and as the compare-deals lifter count: **two
independent lists compared, where either one alone looks complete.** It is the reason the counts in
this estate are trustworthy when they are, and it is the cheapest possible check on this document -
if you disagree with a priority above, write your own column before reading mine.

## What this document is not

It is **not** a design authority. `docs/RUNTIME-MAP.md` is still the architecture document and it
outranks this on any question of what actually runs. This says what the estate is *trying to be good
at*, so that a proposal can be argued against something rather than against taste. **A priority here
that no scenario supports is a priority nobody has tested**, and should be deleted rather than
defended.
