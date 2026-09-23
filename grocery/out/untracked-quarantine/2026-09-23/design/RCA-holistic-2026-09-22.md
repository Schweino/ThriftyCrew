# Holistic root cause, 2026-09-22

Written for Brad by the read-only reviewer. Brad's question: *"identify the overall root cause because we don't want to run into this same issue in the future ... holistic root cause, not just fixing the immediate issue."* The plan that implements this is `grocery/triage-plans/plan-2026-09-22-2.json` (41 items: the 34 open queue ids and 7 discovered items).

## The answer, first

The forty-odd issues of the last three days are not forty defects. They are five process gaps, and every open item and every fix of the last three days lands in one of them. Ranked by how much each explains (open items of 34, plus the last three days' defects I could attribute; a defect that belongs to two gaps is counted under its primary and named under the other):

| Rank | Gap | Open items (of 34) | 3-day defects | The change to HOW WORK IS DONE | Enforced by |
|---|---|---|---|---|---|
| 1 | **F1 Two copies of one fact**, nothing proving they agree | 9 | 9 | A fact has one writer and one road; a second store of it names its reconciler in the same commit, and a projection is regenerated on the road that reads it | a two-writers census over tracked paths (from `ops/count-tracked-writers.ps1`), `verify-commodities-gate -Head` at push, `audit-store-registry -CodeOnly` at push, the sitewide price monitor |
| 2 | **F5 A detector with no resolver**: the alert hands a person a command | 9 | 7 | No alert type is registered without naming what closes it (a lane that consumes the finding, a ruling, or a weekly digest); a body that tells a person to run a command is a finding | `alert-registry.json` gains `resolver`; `audit-alert-registry` fails a page/review type without one; `send-alert` refuses to page one |
| 3 | **F4 A check that cannot tell did-not-look from found-nothing** (or not-yet, or held-on-purpose) | 9 | 7 | Every check states its input's producer slot and its unexamined count beside its findings; a state space of three is never scored with two verdicts | `Get-ProducerSlot` in capture-policy-lib for every absence check; `-COMPLETE` markers carry `not_yet=`/`unexamined=`; held state read through one function |
| 4 | **F2 The production run is the first integration test** | 4 | 8 | A change to a chain script is rehearsed over yesterday's real data in a scratch worktree before it pushes | `ops/rehearse-chain.ps1` + `ops/chain-manifest.json`; pre-push refuses a manifest change with no rehearsal verdict |
| 5 | **F3 All-or-nothing coupling**: one item refuses everything it was handed with | 3 | 4 | A refusing gate declares the unit it refuses at (cell, store, file, slug, board), and board scope must say why | `HOLD SCOPE:` header line checked by `audit-guard-contract`; the daily commit split by owner set (money lane's 148d78) |

F3 is ranked last because Brad's 2026-09-21 ruling already closed most of it (today: 1 cell quarantined, 2,707 published, where 12 of the 25 logged daily runs since 08-24 held the whole board). Its live instance today is the daily commit, which is still all-or-nothing.

**The single sentence:** this estate builds checks faster than it builds the lanes that act on them, keeps the same fact in more than one place, and proves changes against fixtures instead of against yesterday's real data, so a correct detector pages a person, a second copy drifts, and the bot finds out first.

## How this was measured

- Board generation: `comparison-2026-09-22.json` built 08:13:10. The Chrome session landed Aldi, Fareway and Walmart captures at 13:09 to 13:15, after that build; every number below says which it read.
- Corpus: the 34 open queue items and their bodies, plans `plan-2026-09-18` through `plan-2026-09-21-8` (every item's root cause, root fix, leaves_open and deviation), `capture-run-daily-*.log` for 25 logged days 08-24 to 09-22, today's watchdog and capture-run logs, `triage-queue.json` (74 items) plus the untracked archive (357), today's `coverage-gaps.json`, `cell-quarantine.json`, `semantic-findings.json`, `soundness-report.json`, `sale-fallback-gaps.json`, the Sam's capture CSVs of 09-21 and 09-22, and the git history of the checks that failed this morning.
- Rubric: a family is kept only if it explains at least three open items AND at least three of the last three days' defects with a Five Whys chain that ends in a changeable condition. Hypothesis F3 nearly failed that bar on open items (3) and is kept because the daily commit refusal is its live case today.

## F1 Two copies of one fact (9 open items, 9 defects)

**Open items:** a2af45 (the verifier re-derives a basis the engine holds), 8a3090 (the graded tree is not the served tree), bec597 (198 link records hold a price the board no longer publishes), 85c3b7 (one density rule, two builders, one caller), 115180 (a tool page is a third copy of per-serving costs, 19 days stale), 594c27 (169 closes in an archive the RETURN gate cannot see), a25dc0 (rules and their baseline bound at commit, not at push), 274e4b (price-history disagrees with the board on 71 of 7,401 commodity-weeks), 6f90ee. Plus the four discovered items Brad already ruled on (free-chicken-alfredo, 45 articles, the homepage quote, the sitewide monitor) and the RESUME double count.

**3-day defects:** label-prices.json (59 prices read once in July), the stale note in category-excludes.json that two plans quoted instead of the data beside it, the verifier's pack count (a09096) and multibuy (a2af45), hard-coded store lists (175249), price-history vs comparison, a match baseline accepted on disk and never committed (417020), the recall-sleep task reporting `result 0` while its own report says `VERDICT: FAIL`, and today's watchdog printing `ok public\board.json is current with the comparison` six lines above `COMPUTED BUT NOT SHIPPED: M public/board.json`.

**Five Whys.** Why did a tool page show a 19-day-old cost? Because the pipeline rewrote its local source daily and nothing published it. Why? Because the tool's costs are literals copied from the board at build time. Why is a copy allowed? Because the 09-21 ruling that a price renders from the feed at view time was written for recipe cards, and nothing asked which OTHER pages hold a copy. Why did nothing ask? Because the estate has no register of "this artifact is a projection of that one", so each copy is discovered when it drifts, by a person. **Changeable condition:** a second store of a fact is created without naming its reconciler.

**The change to how work is done.** A commit that makes a second store of a fact names, in the same commit, either the road that regenerates it on read (the fill pattern) or the reconciler that compares the two daily (`audit-board-reconciliation.ps1` is the exemplar). Enforced three ways this plan builds: `verify-commodities-gate -Head` at push (rules vs baseline), `audit-store-registry -CodeOnly` at push (rosters vs stores.json), the sitewide price monitor (every live page vs the feed). And one census to add after them: `ops/count-tracked-writers.ps1` already resolves which script writes which tracked path, so a ratchet over "tracked paths with more than one writer" is a two-hour build and would have named price-history, the tool sources and the tile links on day one. It is a ratchet, not a gate red on day one.

## F5 A detector with no resolver (9 open items, 7 defects)

**Measured:** 97 of 431 queue items (queue plus archive) across 18 of 169 types carry a body that hands a person a command: "Run it for the list; fix the lagging side", "Work them with explain-coverage-gap", "After review: -Accept", "fold the change into the local source or -Accept", "Check the task's last run in Claude Desktop". The top three types alone are 53 items: matching soundness review 19, semantic sweep 18, stores dropped 16. Today's chain: `alert-registry FAILED - 26 findings across 97 call-site subjects and 54 queue types`; the registry records class and hold and has no field for who consumes a finding.

**Open items:** 2c96d8 (x10: "fix the lagging side" for six recipes Brad is ruling on), 7d64a6 (RETURN x3), 2dae07, c9f0f3 (an owner label with no worklist behind it), b96f21 (RETURN: 21 rule questions listed daily), 6b17b1 (a band floor refused a real cheaper canola row and the only resolver is a person reading a Sam's page), 4b973e, ceab00, fccb69.

**3-day defects:** the price-flag alert as a daily homework list (fccb69, fired 22 of 30 days until the verifier shipped), the matching review that lived on disk (6f90ee), the semantic sweep paging every lookalike daily (4f01f6, 18 of 29 days), the cost-flags and per-serving manifest pages nobody could act on (fb37b9, bff4ef), the Baker's ad-window page whose remedy named a routine retired on 08-22 (de39ec), the ghost-drift page.

**The proof that the fix works is already in the tree:** the three resolvers built this week each ended a daily page cold. verify-price-flags: 0 new flag pages today, 30 verified quietly. The coverage-gap verdict reader: 476 actionable gaps to 21. The held-state split in cost-recipes: the daily cost-flags page is gone. Every one of them was a detector that had been handing a person homework.

**Five Whys.** Why does the stores-dropped page list the same 21 rule questions every morning? Because nothing consumes them. Why? Because the resolver exists (`explain-coverage-gap` + `apply-coverage-batch`) but no lane runs it. Why? Because an alert type is registered by its condition and class, never by what closes it, so a type can be correct, well-classed and unfinishable. **Changeable condition:** the registry has no resolver field and nothing refuses a type without one.

**The change to how work is done.** `alert-registry.json` entries carry `resolver`: `lane:<script that reads the finding into a worklist>`, `ruling:<question id>`, or `digest` (weekly, never a daily page). `audit-alert-registry` fails a page or review type without one (ratcheted at today's 54 so it is not red on day one), its queue half flags a body with the homework shape, and `send-alert` refuses to page a resolver-less type. The 15 types with no lane yet become digest or ruling until one is built, in order of items: matching soundness 19, semantic sweep 18, stores dropped 16, wrong department 9, recipe db drift 9, link drift 6, Baker's ad window 6, ghost drift 4.

## F4 A check that cannot tell did-not-look from found-nothing (9 open items, 7 defects)

**Open items:** 2000e1 (the watchdog paged MISSING at 10:30 for captures that landed at 13:09 to 13:15; the same report said "nothing outstanding" six lines earlier; 3 of 12 watchdog days), 2c96d8 (held read as drifted), cb8f30 (588 Hy-Vee rows with no product id lead a 15-a-day ask budget they can never satisfy), dca1a1 (52 Sam's rows refused for an unknown unit spelling reached nothing but a rejects file), 1b8544 (a task exit that does not carry its verdict), 149497, a0c785, 8491bf, 2a0748.

**3-day defects:** classify-by-elimination (2a0748: 87% of 517 "dropped stores" were rows correctly withheld), the Hy-Vee `$null` that meant four things (7bac4b), an empty file read as a stripped BOM (148d78), UNKNOWN treated as NOT-CARRIED (0b2f1e: 25 live recipes nearly taken down over a one-day proof gap), test-auditors conflating a live-board red with a blind watcher (ae9df2), the heartbeat paging after an outage for work Windows was about to do.

**Five Whys.** Why did the watchdog page for a capture that arrived three hours later? Because it asks "is there a file dated today" at 10:30. Why at 10:30? Because that is its own schedule. Why does it not know the producer's schedule? Because absence checks here are written as an age against a wall clock (the 09-20 heartbeat fix subtracted machine downtime for the same reason). Why is the report contradictory? Because two checks read one flag file with two questions and nobody compares their answers. **Changeable condition:** a check is written with two verdicts for a three-state world and no statement of when its producer runs.

**The change to how work is done.** Every absence check names its producer's slot (`Get-ProducerSlot`, one helper, read from the task registry) and says NOT YET inside it; every scorer that can be handed a held, withheld or unaskable input reads that state through one shared function and counts it separately on its `-COMPLETE` marker (`unexamined=`, `not_yet=`, `held=`). The guard contract already demands `scanned=` beside `findings=`; this adds the third number. And the exit-code rule from the other side: a scheduled task's exit carries its verdict, or the heartbeat reads the report (Q-4fc24c).

## F2 The production run is the first integration test (4 open items, 8 defects)

**Measured:** of 25 logged daily runs since 08-24, 18 ended with a FAILED LANE (guards-blocked 12, commit-refused 2, commit-size-gate 1, push 2, build-samsclub 1). Of the last three days' defects, 8 were changes that passed the hermetic push gate and failed on the next real board: the empty cost-flags.txt (a 09-21 change) meeting the 09-05 BOM check at 08:xx on 09-22 and refusing the whole daily commit; the verifier (shipped 15:20 on 09-21) giving its first real verdicts at 08:xx on 09-22, one wrong (hummus, pack count) and one a ruling wearing a wrong-price label (yellow pepper); test-flag-verification.ps1 written with two literal store lists and caught by the daily audit 17 hours later; per-cell quarantine's first live run HELD at 10:01 on a staleness precondition; the Sam's cents rendering; the recipe-overlay throw at the 17:23 publish; an -Accept on disk not committed; an alert claiming a quarantine that lands only at the next guards run.

**Open items:** 175249, ca2591, 7c932a, dc1b5b.

**Five Whys.** Why did the daily commit fail on an empty file? Because a hook check reads 0 bytes as "BOM stripped". Why was that not caught at the push that emptied the file? Because the push gate runs fixtures, and no fixture contains yesterday's cost-flags.txt. Why not? Because `run-gates` is hermetic by design (its header rule) and data-dependent audits live in the daily chain. Why is there nothing between? Because the daily chain has one caller, the 08:00 bot, and no rehearsal mode. **Changeable condition:** a change whose inputs are the pipeline's own outputs meets them for the first time in production, by a different actor, at a cost of a day.

**The change to how work is done.** `ops/rehearse-chain.ps1` seeds a scratch worktree with yesterday's real out/ and db/ (seed-worktree already copies the gitignored boards), runs `check-ad-cycles -NoPull -NoCommit -NoPublish` plus the pre-commit hook over the set it would stage, and records a verdict per content fingerprint the way `gate-verdict` does. `ops/chain-manifest.json` lists the scripts whose first real run is the chain; pre-push refuses a push that changed one without a rehearsal pass over data no older than two days. Cost: about 14 minutes (the ship path's own time) per chain-touching push; `-NoRehearsal` is the loud bypass. Its frozen must-fire is today's founding defect: an empty cost-flags.txt against the 09-05 hook. What it cannot catch: a change whose failure needs TODAY's data (the Sam's rendering of 09-21), 1 of the 8.

## F3 All-or-nothing coupling (3 open items, 4 defects)

**Open items:** d16398 (8 delegated audits still hold the whole board; 1 of them has actually held in 30 days), de4f72, da5011. **3-day defects:** one cell holding ~2,700 (fixed 09-21), today's daily commit refused whole for one file, a single live-board case refusing every push on the box (588caa), four catch-all alert types (3e07eb, fixed 09-21).

**Five Whys.** Why did one empty file hold the board, the feed and 540 served files? Because the daily commit is one commit. Why one commit? Because the hook refuses the staged set as a unit and the bot stages the whole refresh. Why does the refusal have no smaller unit? Because a refusing gate's scope defaults to everything it was handed, and scope is added per gate afterwards (per-cell quarantine was added that way on 09-21). **Changeable condition:** no gate declares the unit it refuses at.

**The change to how work is done.** Every delegated guard audit carries a `HOLD SCOPE: cell|store|board - <reason>` header that `audit-guard-contract` checks, so an untaught audit is a push-time finding instead of a board hold; the daily commit is split by owner set (served files, db, captures) so a refused file holds its batch, which is the shape the money lane's 148d78 fix must take.

## What the hypotheses got wrong

- **F1 and F5 swapped places with F2.** The dispatch's order put "production is the first integration test" second; measured, it explains the most defects (8) and the fewest open items (4), because the defects it produces are each closed the same morning. F1 and F5 produce the items that stay open.
- **F3 is mostly closed.** Per-cell quarantine held on its second live day (1 cell, 2,707 published). What is left is the daily commit and the 8 untaught audits, of which 1 has ever held.
- **Two things I could not attribute to any family:** the `git reset --hard` that destroyed 33 foreign files on 09-20 (a working-tree discipline defect, already a rule) and the recipe engine not reading the carriage ledger (a basis-ordering ruling, Q1-2026-09-20-partial-cost).
- **One family the hypotheses did not name and I did not keep:** "a residual written down and not read" (405c73's root fix (a) closed done on 09-21 without being built, then 175249 on 09-22; the RESUME lines double-counting owned residuals). It is F1 (two records of one open thread) and is handled there.
## Rulings that need Brad (recorded in the plan as needs-brad items and open_questions_for_brad)

1. **Q-a2af45-conditional-multibuy.** Is "10 for $10.00 with purchase of 10" the board's price for yellow bell pepper at Family Fare against a $1.99 single? (A) the multibuy is the price with its note (today's cell, $1.00, crown Family Fare); (B) the single is the price (cell $1.99, crown moves to Baker's $1.67); (C) conditional multibuys count only under a household quantity per commodity, which nobody has. Whatever is ruled, the verifier must read the note from the engine's row, or this returns.
2. **Q1-shape-scoped-rulings** (7d64a6). May a known-wrong ruling name a shape rather than one exact product name, and what stops a shape suppressing a product nobody adjudicated? Carried unchanged; nobody has measured what a pattern would suppress across the 326 rulings.
3. **Q-4fc24c-knowledge-store** (4fc24c, 1b8544). Q3 floor snapshot, Q2 reflex caps (4.03% vs 3%, 3.14% vs 2%), the 3 unruled clusters; and may a lane write to `C:\Users\Owner\.claude` to run `recall-reindex.py` inside the pass and make the task exit non-zero on `VERDICT: FAIL` (today it reports `result 0` while its report says FAIL).
4. **Q4-tasks-dead-after-reboot** (8491bf). Auto-logon, active hours, stored-credential tasks, or a boot-time page. 0 recurrences in 6 days; the class stays live until ruled.
5. **q-2026-09-18-4-laundry-scope** (ceab00). One brand line or any liquid detergent per fl oz; and which of the 15 multi-commodity brands on the Baker's ad may admit one commodity each.
6. **Q-homepage-injection-session.** After the alfredo recipe is in the feed, paste the prepared live span into Settings > Code injection (browser-only write).
7. **Q1-2026-09-20-partial-cost.** Carried unchanged; the six held recipes the db-agreement audit paged 10 times about wait on it.
8. **Q-rca-process-changes.** Confirm the implementation order below and the rehearsal's cost (about 14 minutes per chain-touching push).

## The order to implement in

1. **Batch 1, the contracts (no board effect, one push):** the alert resolver contract (F5); triage-return-lib reads the archive and RESUME stops double-counting (F1); `verify-commodities-gate -Head` and `audit-store-registry -CodeOnly` in run-gates (F1/F2); the send-alert footer and worktree refusal (F1); the watchdog's NOT YET (F4); recipe-overlay's self-test (F2); held state in the db-agreement audit (F4); the soundness accept committed with its baseline.
2. **Batch 2, the data-affecting chain changes, one gated rebuild:** price-history keyed on built_at; band-censored rows ride the store re-read; Sam's unit spelling with the per-piece guard and a reject spike page; the Walmart density refusal and caller census; Hy-Vee unaskable rows leave the ask set; the coverage-gap worklist; capture-encoding scopes plus the HOLD SCOPE contract; the link refresh for five stores. Then the chain copied from `check-ad-cycles.ps1`, guards 0 or 4, publish, verify one cell live with a cache-busting query.
3. **Batch 3, the site:** republish the two tools; the four pre-engine posts as engine recipes; the 45 articles in waves with the price-literal gate; the sitewide monitor; then Brad's injection paste.
4. **Batch 4, last:** the chain rehearsal harness, manifest and pre-push clause, with today's empty cost-flags.txt as its frozen must-fire, then a real rehearsal of HEAD before it pushes.

Why this order: batch 1 costs nothing on the board and stops the queue feeding itself; batch 2 is one rebuild for eight items; batch 3 is reader-facing and waits for the feed changes of batch 2; batch 4 changes every future push and should land on a tree whose chain scripts are done moving.

## What I could not prove, said loudly

- The **45 articles** count is Brad's ruling as carried in the dispatch; the corpus is in Ghost and a read-only reviewer did not scan it. The developer's first step is the scan.
- The **8a3090 emitter count** (1 of 36 resolving `out\` from `$PSScriptRoot`) used a narrow text test and is UNSOUND; the honest number needs `count-tracked-writers`' assignment resolution. The four pages in two days are measured.
- **cb8f30's premise** (id-less rows still consume the 15-a-day ask budget after the 09-21 ask-order change) is carried from the ops lane's 09-20 count and marked for verification in the item.
- **6b17b1's band derivation:** whether vegetable-oil's 0.04 floor is derived or typed was not checked; the item says to verify it first, and a typed floor is itself the "no hard-coded bands" rule.
- **The 2000e1 landing-clock table** shows the page preceded the landing on 09-20 and 09-22; on 09-19 the line I matched may have been NO FRESH ROWS (Hy-Vee), not the browser stores. 2 of 3 is the number I stand behind.
- **Cell effects** in the plan: exactly one cell can move by this plan's own changes (vegetable-oil Sam's 0.0723 to 0.0373, and only if the store confirms $7.16); batch 2's Hy-Vee expiry moves an unknown number of Hy-Vee cells that today carry a July price, which the developer counts on the rebuild before publishing.

## Knowledge consulted

Searched (per the dispatch): "root cause process gap", "same fact published twice", "empty file boundary", "all or nothing". Used: `reliability-craft/rca-and-chaos.md` ("The four techniques": fishbone for many contributing factors, Five Whys down each bone to a changeable condition; "a root cause you can fix without changing how work is done is usually not the root cause yet"), `data-quality-craft/diagnosing-a-failure.md` section 3 ("stopping at the cause instead of the CLASS"). Memory hubs read in full: `same-fact-published-twice` (nine memos, the F1 family; `audit-board-reconciliation.ps1` is the exemplar reconciler), `guard-blindness-family` (four arms; F4 is arm 3, "it fired and said the wrong thing", and arm 2's `conformance-guard-cannot-see-rule-bug` is 6b17b1's mechanism). Rules files binding every check proposed: `.claude/rules/ops-and-gates.md` (fixture vocabulary MUST FIRE / MUST NOT FIRE / CLEAN TWIN; never a gate red on day one, ratchet instead; a `-COMPLETE` marker with `scanned=`; a control constant says whether it is a first plausible number) and `.claude/rules/measurement.md` (a rate with its denominator; name the harness and the commit).

## Evidence index (where each number came from)

- 18 of 25 daily runs with a FAILED LANE: `grocery/out/logs/capture-run-daily-2026-0[89]-*.log`, FAILED LANES lines.
- 97 of 431 homework bodies in 18 of 169 types: `grocery/triage-queue.json` (74) plus `grocery/out/archive/triage-queue.archived-2026-09-17.json` (357), regex over bodies, 2026-09-22 13:30.
- 476 to 21 actionable coverage gaps: plan-2026-09-21-7 and `grocery/out/coverage-gaps.json` 08:21.
- 1 cell quarantined of 2,708: `grocery/out/cell-quarantine.json` 08:14:32 and the board's quarantine block.
- 4 of 12 delegated audits scope: grep for `QUARANTINE-SCOPE complete` over `grocery/audit-*.ps1`.
- 52 then 0 Sam's rows printing "fluid ounce (us)": `out/captures/sams-capture-2026-09-21.csv` and `-22.csv`.
- Browser stores landed 13:09 to 13:15 after the 10:30 MISSING page: `out/regular/*-regular-2026-09-22.json` mtimes and `capture-watchdog-2026-09-22.log`.
- Recall task `result 0` vs `VERDICT: FAIL`: the same watchdog log's heartbeat block and `C:\Users\Owner\.claude\recall-sleep-latest.md` 05:49.
- The failing checks' ages: `git log -S 'BOM CHANGED'` (e1acec2a2, 09-05) and `git log --diff-filter=A` for the verifier files (b52b39cc3, 09-21 15:20).
- 6 db-agreement issues, all held recipes: `meal-prep/engine/audit-db-agreement.ps1` run 13:40, rc 1, against `held-recipes.json` per plan-2026-09-20-6.