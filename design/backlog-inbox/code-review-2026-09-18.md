## the price-alert endpoint tells a stranger which emails belong to paying members

`OPEN` `code-review` `2-WAY` `RUNG1 BUILD`

**Source.** Code review against the knowledge store, 2026-09-18, verified in code by the orchestrator.

**What is wrong.** `worker/index.js`, the `/alert` route, looks up the email the CALLER TYPES with
`findMemberByEmail` and answers 200 for a paid or comped member and 403 "members-only perk" for anyone
else. So anyone can post a list of emails and learn who pays, and can switch price alerts on for a paying
member's inbox without that member. The board's client check is UX only, as the route's own comment says.

**The fix, and it also retires redesign C below.** Stop trusting a typed email. The board is served from
thriftycrew.com, so it can fetch the signed-in member's Ghost identity token (`/members/api/session`) and
send it; the Worker verifies the signature against Ghost's published keys and takes the email from the
token. No token, one generic answer. The plan is `design/PLAN-alert-member-token-2026-09-18.md`.
Reversible: the Worker redeploys and the board rebuilds.

**Knowledge consulted.** `security-craft/estate-exposure.md` (section 4, what the estate already gets
right is the server-side check; this route checks the wrong thing); `reliability-craft` was not relevant.

## the public worker holds the full Ghost Admin key on routes anyone can call

`OPEN` `code-review` `2-WAY` `RUNG1 READ`

**Source.** Code review 2026-09-18, redesign C. **What is wrong.** `/alert` and `/submit` run with the
Ghost Admin key in the same Worker that answers the public internet, so one bug in any public route
reaches everything the key can do. Moving member checks to the member's own token (the item above)
removes the admin lookup from `/alert`; `/submit` still needs it. Rung 1 lists every route that touches
the admin key and whether it can be reached without the shared-secret check `notifyAuthOk` gives the
server-only routes. **Knowledge consulted.** `security-craft/estate-exposure.md` sections 1 and 4.

## is the meal plan builder's per-recipe cost and grams meant to be free

`NEEDS A RULING` `code-review` `2-WAY` `RUNG1 RULING`

**Source.** Code review 2026-09-18, verified in the data and headers; the live URL was not fetched.
`public/planner-data.json` is served with open CORS and carries cost per serving and full grams for all
583 recipes, while cost is normally the paid section of a recipe (split at `<!--TC-PAYWALL-->`). **Brad
rules**: if the planner is a free tool on purpose, record that and close this; if not, the file moves
behind the member token the alert fix introduces. **Knowledge consulted.** memory
`paywall-leak-direction-unwatched` (check the direction that loses money).

## the request form creates a ghost draft per call with no login and no rate limit

`OPEN` `code-review` `2-WAY` `RUNG1 MEASURE`

**Source.** Code review 2026-09-18, read from code; no abuse seen. `/submit` in `worker/index.js` makes a
Ghost draft and can send mail from the business address for every request. Rung 1 counts the drafts it
has made per day from the Ghost admin list, so a limit is set from the real rate and not guessed.
**Knowledge consulted.** `security-craft/estate-exposure.md` section 1.

## the null-rate audit counts the sale-ads feed and sams in its pass without checking them

`OPEN` `code-review` `2-WAY` `RUNG1 READ`

**Source.** Code review 2026-09-18, reviewer measured. `grocery/audit-null-rate.ps1` skips those two feeds
and still reports them inside its PASS, and a could-not-evaluate exit sends no alert
(`grocery/capture-run.ps1` about lines 684-686). A skipped feed must be counted as not checked, and a 3
must alert. **Knowledge consulted.** `data-quality-craft/checks-and-thresholds.md` sections 4 and 7.

## the hunt daemon's food-db write has no retry and no lock shared with the retire tool

`OPEN` `code-review` `2-WAY` `RUNG1 BUILD`

**Source.** Code review 2026-09-18, no-retry verified in code, failure measured by the reviewer.
`meal-prep/pipeline/hunt-daemon.py` about lines 2708-2712 replaces the food DB with no retry, and
`retire_food_db_row.py` writes the same file under no shared lock, so a reader holding it open drops the
write and a race loses one. **Knowledge consulted.** `concurrency-craft/durable-file-writes.md`;
`.claude/rules/ops-and-gates.md` (a mutex serialises writers, never readers).

## the capture-cursor log appends with a bare add-content inside an empty catch

`OPEN` `code-review` `2-WAY` `RUNG1 BUILD`

**Source.** Code review 2026-09-18, verified. `grocery/capture-policy-lib.ps1` about line 1239 appends to
`grocery/out/capture-cursor-log.jsonl` with `Add-Content` inside `catch { }`, so a line lost to a
concurrent appender vanishes silently. Route it through `Add-TcLine` (`lib/append-line.ps1`), which the
event bus already uses. **Knowledge consulted.** `.claude/rules/ops-and-gates.md` (an append is not a
locked write); `concurrency-craft/durable-file-writes.md`.

## a ghost update that lands but loses its reply is reported failed on retry

`OPEN` `code-review` `2-WAY` `RUNG1 READ`

**Source.** Code review 2026-09-18, read from code, not reproduced. A PUT that succeeds but whose reply is
lost gets a 409 (stale `updated_at`) on retry and is reported as failed; in the rollback path a drafted
post would read "STILL LIVE". The retry should re-read the post and compare, since only then is the
update idempotent. **Knowledge consulted.** `.claude/rules/ops-and-gates.md` (state whether a retried
operation is idempotent); `lib/ghost-lib.ps1` header (I198).

## the graph import never deletes, so retired commodities keep their prices forever

`OPEN` `code-review` `2-WAY` `RUNG1 MEASURE`

**Source.** Code review 2026-09-18, redesign A. 42 retired commodities still hold 1,043 prices in
`graph.db`, and 19 of their cells land in tracked state daily. Build to a temp file and swap, as
`meal-prep/db/build_db.py` already does. The per-importer atomicity fix landed at 2c6a2b5b5 and is the
first half. **Knowledge consulted.** `database-craft/transactions-and-recovery.md` section 3.

## the push gate cannot see a deleted must-fire case

`OPEN` `code-review` `2-WAY` `RUNG1 BUILD`

**Source.** Code review 2026-09-18, redesign B. `ops/run-gates.ps1` reads each suite's exit code and verdict
line only, so deleting a MUST FIRE case (44 in compare-deals, 50 in wave-preaudit) still passes. Pin case
names as the nightly daemon battery already does (`--names-diff`). **Knowledge consulted.**
`software-craft/test-design-and-oracles.md`; memory `names-gate-cannot-see-a-lost-flag`.

## no board row records when it was captured, which product, or which store id

`OPEN` `code-review` `2-WAY` `RUNG1 READ`

**Source.** Code review 2026-09-18, redesign D. Age survives only in free text, so a stale or wrong-store
price cannot be seen. Additive fields. Overlaps the capture-time item already in the backlog (search
"capture starts recording its capture time"); the merge should fold them. **Knowledge consulted.**
`data-quality-craft/checks-and-thresholds.md` section 1 (freshness).

## price math is tested only with hand-picked examples

`OPEN` `code-review` `2-WAY` `RUNG1 BUILD`

**Source.** Code review 2026-09-18, redesign E. Add seeded property checks to `pricing-math-lib.ps1`'s
suite (ounces and pounds give one unit price; "2 for $5" equals one at $2.50) and run the mutation
harness against it, report only first. **Knowledge consulted.** `software-craft/test-design-and-oracles.md`
section 5.2; `ops/probe-hostile-input.ps1` is the seeded-generator exemplar.
