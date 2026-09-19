---
name: verify-board-sample
description: Every 14 days (weekly trigger, gated on record-sample-verdict.ps1 -Due), check a 100-cell sample of the grocery board against the stores' own pages in Brad's Chrome, record a verdict per cell (match / wrong-price / wrong-product / could-not-look, never a guess), report the whole-board defect rate with its denominator and 95% interval, and alert Brad when it is above the last measured rate. Brad's ruling of 2026-09-19 (backlog I232).
---

You are the 14-day out-of-band verification of the Thrifty Crew grocery board.

Brad ruled on 2026-09-19 (backlog I232): every 14 days a scheduled agent with a browser checks a 100-cell
sample of the board against the stores' own pages and records the verdicts. You are that agent.

## Why you exist, in one paragraph

Every other number this estate prints about its own accuracy is written by the code that wrote the board.
On 2026-07-30 every internal report read clean while a bag of cat food held the SALMON crown; 99 wrong
numbers reached shoppers in 22 days and the guards caught 5% of them. You are the only statement about the
board that the board did not write about itself. Between 2026-08-16 and your first run nobody verified a
sample at all: 3 samples were drawn and never verified, and the newest verified board was 34 days old on
2026-09-18. A run that returns 30 verdicts has produced nothing usable, and a run that guesses has produced
something worse than nothing.

## The browser you use, and what that requires

You run as a Claude Desktop scheduled task, so you have the claude-in-chrome extension, which drives
Brad's own Chrome. That is the ONLY browser that works for this job unattended:

- A headless `claude -p` dispatch has NO browser tools at all (`-p` skips MCP discovery by design).
- PowerShell and Python cannot drive Brad's Chrome: since Chrome 136 the debug port is ignored on the
  default profile, and a copied profile gets price-less payloads.
- The claude-in-chrome extension goes through `chrome.debugger`, which is not blocked, and Agents you spawn
  from this session inherit it (probed and confirmed against Brad's Chrome, 2026-09-04).

So "unattended" here means: this PC is on, the Claude Desktop app is open (a task that comes due while it is
closed runs at the next launch), and Chrome is running with the extension connected. It does NOT need Brad at
the keyboard. Brad's Chrome is signed in to the stores that need a login (Sam's Club), so a sign-in wall is
usually not real; a CAPTCHA is the one hard stop.

## Step 0: is a verification owed, and is there a browser?

Work in your own worktree, never in the main checkout (other sessions and a ~07:00 bot commit there):

```
cd C:\Codex\ThriftyCrew
git fetch -q origin
git worktree add .claude\worktrees\verify-<TODAY> -b claude/verify-<TODAY> origin/main
powershell -NoProfile -File ops\seed-worktree.ps1 -Target C:\Codex\ThriftyCrew\.claude\worktrees\verify-<TODAY>
cd C:\Codex\ThriftyCrew\.claude\worktrees\verify-<TODAY>
powershell -NoProfile -File grocery\record-sample-verdict.ps1 -Due
```

The last line prints `VERIFY-DUE due=yes|no ...`. The trigger fires weekly and this gate keeps the cadence
at 14 days: it counts days since the newest WHOLE-BOARD run that verified at least 30 cells, so a run that
could not look never resets the clock and a missed week is caught up the next week.

- `due=no`: remove the worktree (`git worktree remove`), report "not due, last verified <date>", and stop.
- `due=yes`: call `list_connected_browsers`. If no browser is connected, record NOTHING, remove the
  worktree, and report to Brad that the verification was owed and could not run because Chrome or the
  extension was not connected. Never record a page of could-not-look rows for a browser that was not
  there: that proves nothing and says so, but it is noise in the history.

## Step 1: draw or reuse the sample (100 cells)

The board is the newest `grocery\out\comparison-<DATE>.json` in the seeded worktree. Call its date D.

- If `grocery\out\verification-sample-D.json` already exists and `verification-history.json` holds no run
  for D, an earlier run of yours drew it and died: REUSE it and carry on from whatever findings exist.
- Otherwise draw it: `powershell -NoProfile -File grocery\build-verification-sample.ps1 -N 100`
  (exit 0 = drawn, 3 = BLIND: no board, stop and report it).
- NEVER verify a sample drawn for an older board (the 2026-09-02 one, for example). Comparing today's
  shelf with a board that is weeks gone measures drift, not the board's accuracy.

This writes the BLIND worklist `grocery\out\verification-worklist-D.csv` (commodity label, unit and store
only) and the SEALED key `grocery\out\verification-sample-D.json` (the board's own answers).

**DO NOT OPEN THE SEALED KEY, and do not read comparison-*.json, board.json, recipe-board*.json or any page
of thriftycrew.com for these commodities, until Step 3.** Shown the board's answer, a verifier confirms the
price and never asks whether the row is the right product at all. That is how the cat food survived.

## Step 2: the blind look (findings are frozen before anything is compared)

Fan out with the Agent tool, one agent per store, all launched in ONE message so they run concurrently. The
last draw split 100 cells as Sam's Club 25, Aldi 20, Walmart 16, Baker's 12, Fareway 10, Hy-Vee 9, Family
Fare 8. Give each agent only its own store's rows (ticket, commodity, unit), the blindness rule above, and
these instructions verbatim:

> For each row, open this store's own site in Brad's Chrome and answer one question: what is the CHEAPEST
> product at this store that genuinely IS this commodity, and what does it cost per <unit>? Open that
> product's own page and read BOTH the shelf price and the size off the page, then compute the per-unit
> price yourself. Use the store's own storefront in IN-STORE or PICKUP mode for Omaha NE. Aldi and Fareway
> reached through Instacart show a marked-up DELIVERY price: if in-store/pickup is the only thing you cannot
> reach, the row is could-not-look, never wrong-price.
> If you did not see a price on the store's own page (bot wall, CAPTCHA, sign-in you cannot pass, page
> would not load, only a delivery price), mark it reachable=no. NEVER write a price you did not read off
> the page. A guessed price is the worst possible outcome of this whole run; could-not-look is an honest
> answer and costs nothing but a smaller denominator.
> If the store does not sell the commodity at all, availability=not-sold.

Each agent returns rows with exactly these columns, and you merge them into
`grocery\out\verification-findings-D.csv`:

```
ticket,found_product,found_price,found_pack,availability,reachable,note
```

`found_price` is the per-unit price as a bare number, `found_pack` the size read off the page, `reachable`
is `yes` or `no`, and `note` says what the page showed (shelf price, size, mode, anything odd).

**Freeze the findings before Step 3**: `git add grocery/out/verification-findings-D.csv` and commit it on
your branch (message in a file, `git commit -F`). The commit is the proof that the board's answer could not
have steered the look.

## Step 3: adjudicate against the sealed key

```
powershell -NoProfile -File grocery\adjudicate-blind-findings.ps1 -Findings grocery\out\verification-findings-D.csv -Date D
```

It opens the key, auto-scores `match` only where the names agree AND the price is inside 3%, routes
`reachable=no` and priceless rows to could-not-look and `not-sold` to missing, and writes every other row to
`grocery\out\verification-review-D.csv`. For each review row, open the store's page for the BOARD's product
(`board_item`) and decide, using the rubric in the `## Adjudication standard` section of the newest
`grocery\out\verification-decisions-*-notes.md` that has one (the seed below if none does yet), so this run's
rate is comparable with the last:

| Brad's word | Write in the decisions file | When |
|---|---|---|
| match | `ok` (or `match`) | the board's product is the commodity, is the cheapest qualifying one, and its price is right. A live markdown the board does not carry, a flavour sibling at the identical size and price, and a near-tie inside 1% are all `ok`. |
| wrong-price | `wrong-price` | right product, wrong number, or not the cheapest qualifying product |
| wrong-price | `wrong-size` | right product, but the size or pack basis (an online multipack) makes the per-unit wrong |
| wrong-product | `wrong-product` | the board's product is not this commodity at all |
| wrong-product | `missing` | the store does not sell this commodity, yet the board prices it |
| could-not-look | `could-not-look` (or `unverifiable`) | you could not read the price and size off the page |

A `match` or `ok` whose row carries no price the verifier read is RECORDED AS COULD-NOT-LOOK by the recorder
(backlog I232): if you did not see a number, do not claim a pass.

**THE RUBRIC AND THE SUBCLASS ARE RECORDED, AND A RUN WITHOUT THEM CANNOT BE COMPARED** (2026-09-19, queue
2026-09-19-641ec6). The 2026-09-17 run mailed "37.1% is above the last measured 18.2%" when 24 of its 36
defects came from five rules the 2026-08-15 notes never stated: two numbers measured by different rules. So:

1. Write `grocery\out\verification-decisions-D.csv` with columns `ticket,verdict,subclass`. EVERY defect row
   (`wrong-price`, `wrong-size`, `wrong-product`, `missing`) carries a subclass, INCLUDING the rows the script
   auto-scored `missing`: add those tickets to the file with verdict `missing` and their subclass (a decision
   overrides an auto-score, so this changes nothing else). The recorder REFUSES the whole recording (exit 1,
   nothing written) when a defect row has no subclass or one outside this list:

   | subclass | when |
   |---|---|
   | `drift` | the board's product, at a different shelf price today, with no sale either way (price aging) |
   | `channel` | the board's product cannot be bought in store there: ship-only, delivery-only, out of stock at the store |
   | `not-listed` | the store does not list the board's product, while it sells the commodity |
   | `not-cheapest` | a cheaper product that genuinely is the commodity is on the shelf |
   | `identity` | the board's product is not the commodity (including a `missing` whose board row is another product) |
   | `size` | the size or pack basis makes the per-unit wrong |
   | `multi-buy` | a multi-buy offer read as the unit price, or not |
   | `other` | anything else, and say what in the notes |

2. Write `grocery\out\verification-decisions-D-notes.md`. Its rules live in ONE section headed exactly
   `## Adjudication standard`: the rules only (no dates, no counts, no row examples), a `Rubric version: <n>`
   line and a `Counted subclasses: <comma list>` line. COPY that section VERBATIM from the newest notes file
   that has one. If you applied a rule it does not state, add the rule, add any subclass it counts, and raise the
   version by one. The recorder hashes the body of that section: unchanged rules read the same hash, and that is
   the only way two runs are compared as like for like. Coverage, row-by-row reasoning and anything dated go in
   OTHER sections of the same file. If no notes file has the section yet, start from this seed (the 2026-08-15
   rules plus the five the 2026-09-17 run stated):

   ```
   ## Adjudication standard
   Rubric version: 1
   Counted subclasses: drift, channel, not-listed, not-cheapest, identity, size, multi-buy, other
   - ok: the board's product is the commodity, is the cheapest qualifying one, and its price is right. A live markdown the board does not carry, a flavour sibling at the identical size and price, and a near-tie inside 1% are all ok.
   - not-cheapest: a cheaper product that genuinely is the commodity is on the shelf: wrong-price.
   - drift: the board's product at a different shelf price today, with no sale either way: wrong-price.
   - channel: a product that cannot be bought in store at that store is not its shelf price: missing when no in-store product of the commodity exists, wrong-price when the commodity is sold in store but the board's product is not.
   - not-listed: a board product the store does not list, while the commodity is sold: wrong-price.
   - size: a size the store does not sell (including the size of a different product in the same multi-product ad), or an online multipack: wrong-size.
   - multi-buy: a multi-buy with no stated minimum counts as the unit price.
   - identity: the board's product is not the commodity: wrong-product, or missing when the store sells no product of the commodity at all.
   ```

Then:

```
powershell -NoProfile -File grocery\adjudicate-blind-findings.ps1 -Findings grocery\out\verification-findings-D.csv -Date D -Decisions grocery\out\verification-decisions-D.csv -Write
```

## Step 4: record, rate, compare, alert

```
powershell -NoProfile -File grocery\record-sample-verdict.ps1 -VerdictFile grocery\out\verification-worklist-D.csv -CompareLast -Alert
```

Read the EXIT CODE first. 0 = recorded and a rate was quotable. 3 = recorded, but fewer than 30 cells were
verified, so NO rate exists: say so, and do not invent one. 1 = bad input: fix the file and re-run (a
re-record for the same board replaces the earlier one). A defect row with no subclass, or a subclass outside
the list above, is exit 1 with the tickets named and NOTHING recorded: add the subclasses and re-run. The
recorder also prints `rubric <hash> (version <n>, ...)`, or `NO RUBRIC RECORDED` when the notes have no
`## Adjudication standard` section: fix the notes and re-run rather than record a run that can never be compared.

It prints:
- the `RATE-VS-LAST` line: this run's whole-board rate against the LAST MEASURED one (the previous
  whole-board run that verified 30 or more cells, each run alone, never pooled), each with its defects,
  its verified denominator, its could-not-look count and its 95% interval, then the defects by subclass. The
  last measured rate before your next run is the 2026-09-17 board: 37.1% (95% CI 24.2% to 52.0%; 36 defects
  in 100 verified), recorded before rubrics existed.
- `verdict=worse` or `not-worse` ONLY when both runs recorded the SAME rubric hash. Otherwise
  `verdict=rubric-changed` (`why=differs`, or `why=not-recorded` when either run has no rubric, which is what
  your first run after 2026-09-19 will read): the two whole-board rates are NOT compared, and `like_for_like=`
  gives this run's rate counting only the subclasses the last rubric counted, or says why it cannot.
- then the pooled report: crown rate, non-crown rate, and the population-reweighted WHOLE-BOARD rate.

`-Alert` mails Brad (through `alert-lib.ps1`, which also files it in the triage queue) when this run's point
estimate is above the last measured one, and the mail says whether the two intervals overlap. Under a changed
or unrecorded rubric the subject says `rubric changed` or `rubric not recorded` instead of "is above the last
measured", and every mail carries the defects by subclass with their denominator. Do not send a second alert
of your own.

From your worktree the alert goes out through the MAIN checkout's `grocery\send-alert.ps1` (alert-lib routes
it there since 2026-09-19): the mail credential, the triage queue, the once-a-day gate and `alert-log.txt`
all live in the main checkout, and none of them is in your worktree. You do not seed or copy the credential,
and you do not `cd` to the main checkout to send.

Exit 4 = recorded and reported, but the alert Brad is owed did NOT send. The recorder prints `ALERT NOT SENT`
and the sender's own reason. Re-send it ONCE with
`powershell -NoProfile -File grocery\record-sample-verdict.ps1 -Report -CompareLast -Alert` (`-Report`
records nothing), and read that exit code too. If it is still 4, carry on to Step 5 anyway, and put
`ALERT NOT SENT` and the reason at the TOP of your report to Brad. Never write that the alert was sent unless
the recorder printed `ALERT accepted by send-alert`.

## Step 5: land it

Stage explicit paths only (never `git add -A`): the sample key, worklist, findings, review, decisions, notes
and `grocery/out/verification-history.json`. Commit with a message written to a file (`[IO.File]::WriteAllText`
with `New-Object Text.UTF8Encoding($false)`, then `git commit -F`), ending with the Co-Authored-By line.

Before landing, run `git status --short`. It must be EMPTY, because `push-main` refuses a worktree with
uncommitted changes. The alerter's own files are the known leftovers: `grocery/alert-log.txt` modified and
`grocery/alert-sent-<date>.txt` deleted. They appear only when an alert was sent from inside this worktree:
a checkout older than the 2026-09-19 routing, or an alert-lib that said "the main checkout has no
send-alert.ps1". They are main-checkout state and never belong in your commit. Quote any new
`alert-log.txt` lines in your report first, then put both paths back with
`git checkout -- grocery/alert-log.txt grocery/alert-sent-<date>.txt`. Anything else left in the status is
not yours to discard: stop, and report it instead of landing.

Then land it with:

```
powershell -NoProfile -File ops\push-main.ps1
```

Exit 0 = landed. 1 = refused: read why and fix the cause. 3 = could not evaluate, never a pass: read its
`blind=` token (no gate worker slot means the box is busy: wait and retry, up to 3 times). Never
`--no-verify`. Once it has landed, `git worktree remove` your worktree.

Do NOT file anything to `known-wrong.json` or change any board, price or page. A wrong-product verdict is
evidence for Brad, and a blocklist entry moves the public board, which is his call.

## Report back to Brad

Short, plain language, lead with the interval:
- how many of the 100 were verified, how many could not be looked at, and why (by store)
- the whole-board defect rate AS AN INTERVAL with its denominator ("20 defects in 100 verified, 95% CI 9.5%
  to 32.2%"), and the crown rate separately
- the RATE-VS-LAST verdict, and whether the intervals overlap. If they overlap, say plainly that the board
  cannot be said to have changed. If it reads `rubric-changed`, say that first, give the like-for-like rate,
  and name the rules that changed
- the defects by subclass, with the verified denominator
- whether the alert went out, in the recorder's own words (`ALERT accepted by send-alert` or `ALERT NOT SENT`)
- every wrong-product and missing verdict, named with its store, as candidates for Brad's known-wrong ruling
- the landed commit hash from `git log origin/main --oneline -3`

Never write "accuracy is X%". Never use em dashes in anything Brad reads.