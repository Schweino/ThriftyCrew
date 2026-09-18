# Does a US chain's online produce price move between morning and afternoon?

Backlog **I125**. Bar written **2026-09-12, before the first reading**. Readings **2026-09-13 and
2026-09-14**. Verdict: **CLOSE** - 0 moves over 28 morning-vs-afternoon pairs, read 2026-09-19 (see
[Verdict](#verdict)).

**Harness:** `grocery/probe-produce-intraday.ps1`, landed at **`62a2d10d0`**.
**Panel and bar:** `grocery/produce-intraday-panel.json`, pinned at the same commit.
**Readings:** `grocery/out/produce-intraday.jsonl` (gitignored, main checkout).
**Verdict file:** `grocery/out/produce-intraday-verdict.json`, rewritten by every reading.

## Brad's ruling, 2026-09-12, verbatim

> Yes, produce is compared store to store on the board, so this is worth the one hour. Run the cheap
> test once: one produce commodity at one chain store, priced online morning and afternoon on the same
> day, repeated on two days. If no price moves, record that US chain online produce prices here do not
> move intraday and close it. If any move, every capture starts recording its capture time (hour and
> timezone) alongside asof, and nothing else changes until that data shows a pattern.

## Why the question is live

The course behind I125 says perishables are marked down intraday as routine yield management. Its
example is an unorganised vegetable market, not a chain supermarket, and the item was registered as
claim C178 precisely because that generalisation is not something the course supports.

It matters here because the board compares seven Omaha stores against each other and every capture
this estate takes lands in ONE morning window. The whole vocabulary for row freshness is DAYS -
`asof`, `grocery/audit-row-age.ps1` - and no capture records a time of day. If a chain repriced
produce during the day, a board comparing stores captured hours apart would be comparing different
afternoons, and no field we store could say so.

## The existing captures cannot answer it

Measured 2026-09-12 over `grocery/out/captures/`, `grocery/out/regular/` and `grocery/out/archive/`:
**5,682 files**, grouped by name-with-the-date-stripped plus the date, giving **421 groups**, of which
**30 hold more than one file** and **2 span more than three hours**. Both of those two are rebuilds of
an earlier day under a later mtime (`walmart-regular-2026-07-23`, `candidates-2026-07-05`), not a
second reading of the same day. Every per-store file in `regular/` was written between 08:00 and
12:00.

So there is no same-day morning-and-afternoon pair anywhere in the history, and the test has to be run
forward.

## Design

| | |
|---|---|
| Store | Baker's Saddlecreek, Omaha 68106, `locationId` 61500319. ONE store, as ruled. |
| Channel | Kroger's public per-store product API. Headless, no browser, no session, so it can run unattended. |
| Price read | `promo` when the store has a live promo, else `regular` - what the store charges today, the same rule `grocery/pull-regular-bakers-api.ps1` publishes on. |
| Products | 15, pinned by `productId`. 12 highly perishable, 3 long-shelf-life controls. |
| Windows | 08:30, 15:30 and 20:00 local (America/Chicago, -05:00). |
| Days | 2026-09-13 and 2026-09-14. |

**Three details the ruling left open, and what was chosen.**

1. **Fifteen products rather than one.** The marginal cost of the fifteenth is one HTTP call inside
   the same hour, so the choice was between a verdict that closes the item forever on a single row and
   one that does not. A single commodity could be a fixed-price outlier and nothing in the result would
   say so. Twelve are the most perishable produce the board carries, because a
   markdown-on-perishables claim is only testable where a markdown would happen; three are controls,
   so a store-wide reprice can be told apart from a perishable markdown.
2. **Pinned by `productId`, never by search term.** Kroger's search ranking moves on its own, so a
   top-hit against a top-hit would report a ranking change as a price change - the exact confound this
   measurement exists to rule out.
3. **A third reading at 20:00, reported separately and OUTSIDE the verdict.** The ruling names morning
   and afternoon, so that is what decides. A late markdown is the likeliest shape there is, though,
   and a "no move" verdict that never looked after 15:30 is worth less to whoever reads it next.

**The window is read from the hour a reading actually happened at**, never from the trigger that was
meant to fire it. The task runs `StartWhenAvailable`, so a box asleep at 08:30 produces a reading at
noon, and labelling that "morning" would manufacture a deciding pair out of two afternoon prices.

## The acceptance bar, written before the first reading

A **deciding pair** is one product, one date, its morning price against its afternoon price, both read
ok. A **move** is a difference of at least **$0.01**, compared on the raw difference. **30 pairs are
planned** (15 products x 2 days).

| Outcome | Condition | What it means |
|---|---|---|
| **CLOSE** | 0 moves AND at least 24 readable pairs | Record that US chain online produce prices here do not move intraday. Close I125. Change no capture schema. |
| **OPEN** | at least 1 move | Every capture starts recording its capture time (hour and timezone) alongside `asof`, and nothing else changes until that data shows a pattern. |
| **BLIND** | anything else | A could-not-look must not settle the question. Not a CLOSE. |

A day-to-day or morning-to-morning difference is **not** a move here. That is the ad cycle, which the
`asof` machinery already handles, and counting it would answer a different question with a right
number. A product that errored or returned no price is counted and named, never scored as "did not
move".

The same bar is stated in three places that must agree: the harness header, `bar` in
`grocery/produce-intraday-panel.json`, and this table.

## The panel, and the pilot reading

Taken 2026-09-12 at 15:28:45 -05:00 through the harness, exit 0, **15 of 15 products read, 0
unreadable**. Every price equals the value pinned in the panel, so the panel is verified against the
live API rather than asserted.

| Commodity | Kind | productId | Product | Size | Price at pin |
|---|---|---|---|---|---|
| strawberries | perishable | 0003338320027 | Fresh Strawberries, 1 LB Clamshell | 1 lb | 3.99 |
| raspberries | perishable | 0003338321000 | Fresh Red Raspberries, 6 OZ Clamshell | 6 oz | 2.50 (promo, reg 3.29) |
| blueberries | perishable | 0003338322101 | Fresh Blueberries, 1 PT Clamshell | 1 pt | 4.79 |
| spring-mix | perishable | 0001111091052 | Kroger Baby Spring Mix | 10 oz | 3.99 |
| spinach | perishable | 0001111091649 | Kroger Tender Baby Spinach Bag Salad | 10 oz | 2.49 |
| lettuce | perishable | 0000000004640 | Romaine Lettuce | 1 ct | 2.79 |
| asparagus | perishable | 0000000004080 | Green Asparagus | 1 lb | 3.69 |
| fresh-green-beans | perishable | 0000000004066 | Fresh Bagged Green Beans | 1 lb | 2.19 |
| broccoli | perishable | 0000000003082 | Broccoli Crown | 1 lb | 2.19 |
| cherry-tomatoes | perishable | 0001111091686 | Kroger Fresh Grape Tomatoes | 10 oz | 2.99 |
| mushrooms | perishable | 0001111091011 | Kroger Whole White Mushrooms | 8 oz | 2.39 |
| avocados | perishable | 0000000004046 | Fresh Medium Ripe Avocado | 1 each | 1.00 |
| bananas | **control** | 0000000004011 | Fresh Bunch of Bananas, 5-7 Bananas | 1 lb | 0.55 |
| russet-potatoes | **control** | 0000000004072 | Russet Potato | 1 lb | 0.89 |
| onions | **control** | 0000000004093 | Jumbo Yellow Onions | 1 lb | 1.19 |

The pilot is a single afternoon reading, so it forms no deciding pair, and the harness said so:
`VERDICT: BLIND ... 0 price move(s) of at least $0.01 over 0 morning-vs-afternoon pair(s) (planned 30,
bar 24)`. That is the abstention branch working on live data before the measurement starts.

## What a CLOSE would and would not say

It would say: at this banner, at this store, over these fifteen products, on these two days, the
online price did not move between morning and afternoon.

It would **not** say a different banner does not move, that the in-store shelf tag does not move (this
reads the e-commerce price, which is what the board publishes), or that nothing moves after 20:00.
The evening readings bound the third of those a little and are reported beside the verdict.

## Verdict

**CLOSE. At this banner, at this store, over these fifteen products, on 2026-09-13 and 2026-09-14,
the online price did not move between morning and afternoon.** US chain online produce prices here do
not move intraday on this evidence, and no capture schema changes.

Read 2026-09-19 by `grocery/probe-produce-intraday.ps1 -Verdict` at `f092c8d57` (harness blob
`3d87ef06f121`, panel blob `ae20203f7462`), over a copy of the main checkout's
`grocery/out/produce-intraday.jsonl` (105 rows, sha256 `DD3376436B3F...`). Exit **0**, verbatim:

```
produce-intraday VERDICT: CLOSE - No intraday movement found. Record that US chain online produce prices here do not move intraday, close I125, change no capture schema.
  deciding: 0 price move(s) of at least $0.01 over 28 morning-vs-afternoon pair(s) (planned 30, bar 24), 15 product(s) across 3 day(s)
  supplementary (NOT in the verdict): 0 move(s) over 30 afternoon-vs-evening pair(s)
  rows read 105, unreadable 2
    could not look: 2026-09-13 morning spring-mix: error:The remote server returned an error: (503) Server Unavailable.
    could not look: 2026-09-13 morning broccoli: error:The remote server returned an error: (404) Not Found.
```

**The readings happened when they were meant to.** Every one of the six scheduled readings is stamped
at its trigger minute plus one second (08:30:01, 15:30:01, 20:00:01 -05:00 on both days), so no window
label was manufactured by a late start. All 90 scheduled readings ran through the same harness blob
`3d87ef06f121` that scored them, although the `harness_commit` field names three different commits
(`18a19b5fe`, `f413337d2`, `560d7d133`) because it records the checkout's HEAD at read time. The pilot's
15 rows ran at `62a2d10d0` (blob `c6eaa2485c1f`) and form no deciding pair. Every row carries the one
panel sha256 `BBD767D385B8...`.

**The two could-not-looks cost two pairs, both on 2026-09-13's morning, and neither is scored as "did
not move".** 28 of the 30 planned pairs decided, against a bar of 24. Both products read cleanly at
the other five scheduled readings.

**The deciding pairs**, morning (08:30) against afternoon (15:30), in dollars. Every one has a delta of
0.00:

| Commodity | Kind | 2026-09-13 | 2026-09-14 |
|---|---|---|---|
| strawberries | perishable | 3.99 / 3.99 | 3.99 / 3.99 |
| raspberries | perishable | 2.50 / 2.50 | 2.50 / 2.50 |
| blueberries | perishable | 4.79 / 4.79 | 4.79 / 4.79 |
| spring-mix | perishable | could not look (503) | 3.99 / 3.99 |
| spinach | perishable | 2.49 / 2.49 | 2.49 / 2.49 |
| lettuce | perishable | 2.79 / 2.79 | 2.79 / 2.79 |
| asparagus | perishable | 3.69 / 3.69 | 3.69 / 3.69 |
| fresh-green-beans | perishable | 2.19 / 2.19 | 2.19 / 2.19 |
| broccoli | perishable | could not look (404) | 2.19 / 2.19 |
| cherry-tomatoes | perishable | 2.99 / 2.99 | 2.99 / 2.99 |
| mushrooms | perishable | 2.39 / 2.39 | 2.39 / 2.39 |
| avocados | perishable | 1.00 / 1.00 | 1.00 / 1.00 |
| bananas | control | 0.55 / 0.55 | 0.55 / 0.55 |
| russet-potatoes | control | 0.89 / 0.89 | 0.89 / 0.89 |
| onions | control | 1.19 / 1.19 | 1.19 / 1.19 |

**The evening readings (outside the verdict) did not move either:** 0 of 30 afternoon-vs-evening pairs.

**One thing the data shows that the bar did not ask, and what it limits.** Every product read the
SAME price at every one of its 103 readable readings across all three dates, the pilot included, so
there was no day-to-day move either. That is consistent with prices that simply held for the
weekend (Saturday 2026-09-12 to Monday 2026-09-14), and it is also what a feed that republished one
fixed daily or weekly price would look like. This measurement cannot tell those two apart, and it
does not need to: the board publishes this same e-commerce price, so a price that does not move in the
feed does not move on the board, whatever the shelf tag does. It is the reason the CLOSE says "online".

## Status

**2026-09-19: steps 1 to 3 below are done** (verdict above, I125 closed). **Step 4 is done too: the
probe, its panel, its task definition, its watch row, its census entry and its two `.gitignore` lines
were removed by the commit on branch `claude/i125-probe-removal`**, landed after Brad unregistered the
task, because an agent does not change a Windows scheduled task on this box. The harness survives in
git history as blob `3d87ef06f121` if the question is ever re-asked.

**The stale page is not sent once.** health-heartbeat dedups on a signature of its issue text, and a
TASK STALE line carries the task's age in hours (`last ran 87.5h ago` when read on 2026-09-19), so the
signature changes every run and the page can repeat at every heartbeat until the task is gone. The paragraph below
assumed it would page once.

Readings are driven by a **bounded** Windows task, `TC Produce Intraday Probe`: six one-time triggers
and then it is inert, so nothing permanent is added to this box. It is watched in
`grocery/expected-automations.json` with `max_age_hours` 14, which is over every planned gap and under
the 12.5 hours from the 20:00 reading to the next 08:30 one - so a **skipped** reading pages at the
next 10:30 heartbeat while the measurement can still be re-run.

**When the last reading is done the row goes stale on purpose and health-heartbeat pages once.** That
page is the handoff, and it names this file. A two-day measurement whose last step is "somebody
remembers to read it" is an intention, and an intention has no exit code.

**Whoever picks up that page does this:**

1. `powershell -NoProfile -File grocery\probe-produce-intraday.ps1 -Verdict` and read the exit code
   (0 decided, 3 BLIND).
2. Paste the verdict block and the deciding pairs into this file under a `## Verdict` heading, with
   the date read.
3. CLOSE or OPEN I125 in `design/BACKLOG-course-findings.md` according to the bar above. Nothing else.
4. Delete the whole probe together: the task, its row in `grocery/expected-automations.json`, its
   entry in `grocery/audit-script-census.ps1`, `ops/scheduled-tasks/tc-produce-intraday-probe.xml`,
   `grocery/probe-produce-intraday.ps1`, `grocery/produce-intraday-panel.json` and the two `.gitignore`
   lines. A bounded measurement that outlives its question becomes a daily routine nobody chose.

If the verdict is **BLIND**, do not close the item: edit `plan.dates` in the panel, re-run `-Install`,
and take the readings again.
