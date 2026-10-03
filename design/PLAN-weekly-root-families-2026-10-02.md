# PLAN: stop the weekly pile at its source (six root families behind 27 open items)

**Status: RULED 2026-10-02 (D1 A, D2 A, D3 A by Brad; D4 is his own read, outside this plan). Phases 0 to 6 built and landed on origin/main 2026-10-02; their bar windows run 2026-10-02 to 2026-10-17 (dates in each phase). Phase 7: detective wording landed, three rulings waiting (`design/ready-for-brad/weekly-root-families-phase-7.md`).**

Written by the 2026-10-02 triage orchestrator at Brad's request ("26 weekly items screams systemic issue"). It is meant
to be handed whole to a fresh session. That session reads this file, the plan it extends
(`PLAN-zero-alert-days-remainder-2026-09-24.md` in `design/`), and nothing else before Phase 0.

## 1. Decisions for Brad (each blocks only the phase named)

**D1. Start step 8's shadow now, or keep the ruled order?** (blocks Phase 2) (RULED A by Brad, 2026-10-02, "A: shadow now (Recommended)")
The ruled order (2026-09-10) is R18, then R11, then the 3b decision, then steps 8 to 11. None of R18, R11 or 3b has
moved since 2026-09-24, so the row contract has waited 22 days behind them while its symptoms keep arriving.
- **A (recommended):** write the contract and run it in SHADOW now, beside R18 and R11. Shadow refuses nothing and moves
  no price, so it cannot conflict with a capture change. Enforcement for a store still waits until that store's
  capture work (R18 for Walmart and Sam's, R11 for Aldi and Fareway) has landed. Consequence: about 3 weeks earlier
  evidence on the 7 basis items; the contract may need one revision when R11 changes the Aldi and Fareway rows.
- **B:** keep the ruled order. Consequence: step 8 starts only after R18, R11 and 3b, and the basis items keep
  arriving one at a time until then.

**D2. A new step for the daily chain's data flow (family 5, not covered by any ruling).** (blocks Phase 5) (RULED A by Brad, 2026-10-02, "A: pin + gate (Recommended)")
- **A (recommended):** each daily run pins ONE board generation at its start, and every consumer (guards, the feed
  export, the post builder, the deals page) reads that pin instead of choosing "the newest file" itself. The chain's
  step order is checked against a declared input/output list, so a step that reads a file before its writer runs
  fails a gate. Consequence: one new lib and a gate; touches the chain script.
- **B:** leave the 4 items as weekly items and fix each by hand. Consequence: the class keeps recurring.

**D3. How the weekly lane keeps up.** (blocks Phase 1) (RULED A by Brad, 2026-10-02, "A: owned-by-step (Recommended)")
It runs about 150 tool calls a week at about 40 per item, so about 4 items. Triage minted 81 "triage residual" or
"triage finding" items in the 15 days the queue holds (2026-09-18 to 2026-10-02, any status), about 38 a week, and 26
of today's 27 open items were born after the lane's last run (2026-09-27 11:06).
- **A (recommended):** a residual whose root family already has a ruled, unbuilt step is NOT minted as a queue item.
  It is recorded against that step (`leaves_open_followup: "step:<plan file>#<step>"`) and counted there. The gate
  accepts that owner only for a step whose plan status is RULED or under way. Consequence: no extra token cost; the
  queue shrinks to work that has no owner.
- **B:** raise the weekly lane's budget. Consequence: more tokens every week, same inflow.

**D4. The knowledge store item (2026-09-29-a82e6c) is waiting on your judgement already** ("forgetting" and "gate"
steps of the nightly pass, report at `~\.claude\recall-sleep-latest.md`). It is not grocery work and this plan does
not touch it. It needs your read of that report.

## 2. The finding this plan acts on

Measured 2026-10-02 from the triage queue file (27 open, all weekly lane) and the alert census:

- **21 of the 27 were created by triage itself** (types beginning "triage residual" or "triage finding"); the other
  6 are review-class alerts born weekly by design, plus the knowledge store item. A run fixes the slice in front of it
  and files the rest: 81 such items in 15 days, against a lane that works about 4 a week.
- **Census, last 30 days:** 473 alerts, 149 of them a type triage had already closed (31.5%), 61.1% when counted by
  class, 200 queue items minted. Quiet days: 2 of 30.
- **Most items are symptoms of rulings that were never built.** The 2026-09-10 rulings (row contract, two-signal
  identity, review packet) target exactly the families below, and the remainder plan's status line still reads "not
  started". Triage pays for their symptoms one at a time, at full diagnosis price.

### The six families (one row per item; read from each item's own body, re-verified in Phase 0)

| Family | Root cause, one level up from the instances | Prevented by | Items |
|---|---|---|---|
| 1. Row basis | Size, unit kind (weight, volume, count), pack count and deal terms are decided by each store builder separately, then re-decided by the engine and again by each guard. Two readers of one token disagree. | Step 8, row contract (ruled) | 9ee1f9 Hy-Vee pack x size; 7c3a24 N-for-M with no count; 6adf51 multibuy missing pack count; 1eac5a Sam's count-per-pound; 35fdeb pack-factor guard exempts sale classes; 44c416 fl oz read as weight oz (410 rows, 35 commodities); ab2257 band refusals with no basis evidence |
| 2. Identity by name alone | A product's commodity is decided by include/exclude patterns on its NAME, one signal. Each fix is another pattern, which moves products from one wrong commodity to another (184b1d and 356c4e say so in their bodies). | Step 9, two-signal identity (ruled) | 6fc290 household lines routed to food, store department unread; 184b1d 4 keys need a two-rule fix; 356c4e tissues moved by a lotion exclude; 465acc 3 cells need a product-detail read; 88bd45 quarantine on one signal hits good cells; 1ed278 recipe route and identity leftovers |
| 3. Review alerts with no adjudication | Review-class detectors queue every finding, including ones an earlier ruling or a committed routing artifact already explains. | Step 11, review packet with auto-adjudication (ruled) | a57d2e new contested; 0210a6 stores dropped; 8415b9 semantic sweep; dc03c3 soundness roll-up duplicates |
| 4. Capture coverage | Family Fare's everyday prices are re-read on a deliberate 86-day rotation (7 of 602 terms a day, Brad's ruling 2026-09-03, memory `ff-term-budget-is-quarterly-by-design`), so a sale cell whose everyday term is not due has no row to fall back to when the sale ends. The 7-a-day budget is NOT a throttle defect and is not to be "fixed". What is open is whether a sale-ending cell's term should jump the rotation. | 3b catalog walk (trial done, not built), or a ruling on rotation priority | e40f92 (its body calls the rotation "throttled"; Phase 0 re-reads it against the ruling); e7f9b9 5 sale cells with no fallback (the same cells) |
| 5. Chain data flow | Each consumer picks "the newest board" by its own rule, and the step order is maintained by hand, so outputs lag or disagree. | NEW, needs D2 | c6bafd feed one run behind top5; 1d4206 post and feed from different boards; 2bcd10 foreign writers during the chain; 871301 stale-artifact check unsound at 8 sites |
| 6. Traps enforced by memo | Known PowerShell and test-load traps are written in rules and memories, but only some have a gate. | Gates (Phase 6) | 3849bc ConvertFrom-Json array collapse, 90 sites; c12baf self-test depends on box load; ae8b7a match-lib reds under load |
| none | Outside grocery | D4 | a82e6c knowledge store judgement |

7 + 6 + 4 + 2 + 4 + 3 + 1 = 27. **This grouping is the orchestrator's reading of titles and the first 420 characters
of each body. It is an input, not a measurement; Phase 0 measures it.**

## 3. Phases

Each phase works in a linked worktree, commits with a pathspec and a `Store:` line, and lands with push-main (`push-main.ps1` under `ops/`)
(rule og-47: never `git push origin HEAD:main`). Plan and verify at high effort, implement at medium (ThriftyCrew
`docs/EFFORT-GUIDE.md`). Board steps, guards and reconcilers run in a scratch clone, never the checkout you land from.
Each phase ends with its bar read and recorded in this file's status line, and the weekly items it covers re-measured
and closed through `triage-close.ps1` (under `grocery/`) with the step named in the note. An item the phase does not reproduce
is closed as such, with before and after numbers. **An alert going quiet is never the evidence for a close**
(`reliability-craft/MAP.md` section 5: "a silenced symptom and a fixed cause look identical from the alert's side");
the close names the measurement that shows the cause gone.

### Phase 0. Measure the families (one session, no code; about 2 hours)

1. For each of the 27 items, read its full body and its source plan item, and write one row: id, family, the step
   that prevents it, and whether it still reproduces on today's board. Write the rows to
   `design/MEASURE-weekly-root-families-2026-10-02.md`.
2. Do the same for the census's top 10 recurring types (by days fired, last 30 days): which family, which step.
3. **Bar, written now:** at least 22 of the 27 (81%) map to one of the six families with a named preventing step. If
   fewer do, stop and re-plan; a family that does not exist cannot be fixed at the source.
4. For families 1 and 2, count how many alerts in the last 30 days came from each (the census by type, joined to the
   family rows). That count orders Phases 2 to 4.

**Result, 2026-10-02** (`design/MEASURE-weekly-root-families-2026-10-02.md`): bar MET, 25 of 27 (92.6%) map to a
family with a named preventing step; `a82e6c` (D4) and `1ed278` (recipe-side leftovers, no single owner) do not. A
stricter reading (the step covers every instance inside the item) gives 21 of 27 and exposes one missing step: 5 of
today's 8 no-fallback sale cells are Hy-Vee, which the Family Fare rotation does not explain (carried into Phase 7).
30-day census by type: 154 of 473 alerts map to a ruled step (step 11 86, Phase 7 18, step 8 16, Phase 5 16, step 9
11, Phase 6 7); 100 more are triage's own items. Family 1 (16 typed + 7 items) outranks family 2 (11 + 6), so
Phase 2 leads Phase 3.

### Phase 1. Stop the queue feeding itself (needs D3; one session)

1. **Owner by ruled step.** Teach `validate-triage-plan.ps1` to accept `leaves_open_followup: "step:<plan>#<n>"` when
   that plan's status line reads RULED or under way, and refuse it for a DONE, PROPOSED or missing plan. Fixtures:
   MUST FIRE (a step owner on a DONE plan is refused), MUST NOT FIRE (a RULED plan's step is accepted), CLEAN TWIN
   (`watch:` and queue-id owners still work).
2. **Re-home the open items.** Each item whose Phase 0 row names a ruled, unbuilt step closes with disposition
   `owned-by-step` and its body is appended to that step's evidence section in the remainder plan. Items with no step
   stay in the queue.
3. **Stalled-ruling page.** `audit-alert-census.ps1` gains one line per ruled step: alerts attributed to it in the last
   14 days, and days since it was ruled. A ruled step that is not under way 14 days after its ruling, with attributed
   alerts, pages once a week as `ruled step stalled`, registered in the alert registry. This is what would have caught
   the 22-day stall. Fixtures: at-bar (exactly 14 days) and one past it (rule og-06). **When the producer stops**
   (rule og-13): if the census attributes 0 alerts to every ruled step for 7 days while alerts were raised, the
   attribution is broken, not the program quiet, and the line reads BLIND and pages as such.
4. **Bar:** over the 14 days after landing, triage-made queue items (`type` beginning "triage residual" or "triage
   finding", any status) number at most half of the 14 days before landing, and the census's returns30 does not rise.
   Baseline measured 2026-10-02: 81 in the 15 days 2026-09-18 to 2026-10-02 (the queue holds no older rows, so the
   pre-landing window is re-counted on landing day from the queue, not taken from this line). Write both counts with
   their windows.

**Built 2026-10-02.** Step 1: `validate-triage-plan.ps1` accepts `step:<plan>#<label>` through
`grocery/ruled-step-lib.ps1` `Test-StepOwner`, which asks `plan_citation.py --plan-state` under `ops/` (one copy of the
Status rule) and also refuses a step heading that reads `[DONE`; the cases live in the validator's piece
`validate-triage-plan/step-owner.ps1`. `triage-close.ps1` gained the disposition `owned-by-step` (a hit), refused
unless its notes name a step owner that resolves. Step 3: the census's RULED STEPS line, map `grocery/ruled-steps.json`,
pages `Ruled step stalled: <ref>` and `Ruled step attribution BLIND` on Mondays (both registered). Its first live read
(2026-10-02, -NoPage) put steps 8, 9 and 11 at STALLED, 22 days, with 15, 6 and 56 attributed alerts over 14 days:
the founding case. The triage skill's COST CONTROLS (rule 4) and both developer agents teach the new owner.
**Step 2 deviates on purpose:** an item's body is NOT appended into the remainder plan. Those bodies name about thirty
repo paths (pricing-math-lib, compare-deals, the builders), and the plan-citation check would then ask every commit to
those files to cite the remainder plan, the exact defect that plan's section 1 was written to avoid (83 of 86
warnings). The bodies go to `design/EVIDENCE-weekly-root-families-2026-10-02.md`, which has no Status line and is not
judged, with one pointer line per step in the plan.
**Bar, counted 2026-10-02:** 81 triage-made items in the 14 days 2026-09-19..2026-10-02 (the queue's oldest row is
2026-09-18), so the bar is at most 40 over the 14 days after landing, with returns30 at or below 149 (31.5% of 473).

### Phase 2. Step 8, the row contract (needs D1; several sessions)

As ruled and barred in the remainder plan, section 2, step 8. Do not restate or reinterpret its bar; it is Brad's.
1. `design/SPEC-capture-row-contract.md`: the contract. Each captured row carries size value, size unit, unit kind
   (weight, volume, count), pack count, price basis (each, per unit, pack total), and deal terms (N for M, buy N get
   K, rollback, TTL), each with its source field and a refusal code when it cannot be proven. A volume size on a
   weight-unit commodity is refused unless the commodity declares a density, which settles 44c416 at the source.
2. `grocery/row-contract-lib.ps1`: one validator. The engine's unit conversion and every basis guard read the
   contract's unit kind instead of parsing the size again (this removes the two-reader disagreement in 44c416 and the
   pack-count disagreements in 9ee1f9, 7c3a24 and 6adf51).
3. Shadow for 7 days per store across the seven builders and the two batch importers (input I165), with a daily
   shadow report naming every cell the contract would empty.
4. Enforce store by store in the census's order of returns. Per-store bar, verbatim from the ruling: "after
   enforcement, 0 basis-class guard hard fails from that store over 14 days, and every cell the contract empties is
   one the shadow report already named."
5. Turn on ruling 6: the weekly lane's `new_source_check` starts checking new stores, feeds and large batches against
   the contract.

**Landed 2026-10-02** (937809e08 is the last of its commits on origin/main). `design/SPEC-capture-row-contract.md`,
`grocery/row-contract-lib.ps1` (one validator over the existing parsers, 42 fixture cases from each instance's real row
text), and a daily SHADOW lane `grocery/audit-row-contract-shadow.ps1` over the engine's candidates and all seven
builders' outputs (no builder changed: every one already carries the source text the contract needs). Ruling 6 is live:
`validate-triage-plan.ps1` refuses the old "no contract exists" wording and a new source with no shadow line quoted; the
triage skill says so. First shadow run (candidates-2026-09-30): would refuse 431 of 22,280 engine-priced rows (1.9%) and
empty 26 of 2,916 priced cells, 24 of them fl oz sizes on 11 oz-unit commodities (the 44c416 class); 23 of 1,317
out-of-band rows carry a basis refusal code (ab2257's missing evidence). The rules were tuned twice against that file, so
the next 7 daily runs are the independent test. Landing found the lane launched and never read (test-auditors u049); it
is now read like step 9's. **Waiting:** 7 shadow days per store end 2026-10-09; enforcement for Walmart and Sam's waits on
R18 and for Aldi and Fareway on R11 (D1), and the 11 oz-unit commodities need Brad's call (density, unit change, or let
their fl oz rows leave the board), in `design/ready-for-brad/weekly-root-families-phase-7.md`.

### Phase 3. Step 9, two-signal identity (several sessions, mostly waiting on shadow)

As ruled in the remainder plan, step 9, with its bar verbatim: measure each store's category coverage first, 14 days
of shadow on crowns, enforce only if a hand-checked sample of at least 30 disagreements is at least 80% real wrong
products and enforcement empties no more than 2% of live cells. The second signal settles 6fc290 (store department),
and replaces the single-signal quarantine trigger behind 88bd45. The shadow report should name every family 2 item, so
the step's effect on them is visible before enforcement.

**Landed 2026-10-02** (601e96fbc). `grocery/audit-store-category-share.ps1` and
`grocery/audit-crown-identity-shadow.ps1`, wired once into the daily chain, shadow only. Coverage: 11,698 of 22,129
captured rows (52.9%) carry a usable store department; Walmart, Sam's Club and Aldi capture none, so 476 of 577 crowns
(82.5%) read no-signal and the second signal can judge 101. First shadow day: 99 agree, 2 disagree. One disagreement was a
live wrong cell: fresh cranberries at Baker's held by "Kroger Sweetened Cranberries", a dried product, fixed the same day
by a `\bsweetened\b` exclude (fresh-cranberries 1 -> 0 cells, no other move). For the family-2 items: Glad bags disagree
(the signal would have caught 6fc290); Del Monte peas and carrots, olive oil mayo and the sun-dried jars agree (form
questions inside one department, which this signal cannot settle); the rest read no-signal. **Waiting:** 14 shadow days
end 2026-10-16, then the ruled hand check of 30 disagreements; at about 2 a day, mostly repeats, 30 distinct ones may take
longer, which the step's own note records as an input for revisiting the first-guess bar.

### Phase 4. Step 11, the review packet (one or two sessions)

As ruled in the remainder plan, step 11, with its bar verbatim: the five review types page on at most 4 of 14 days
while the packet carries every row the alerts used to. Fold dc03c3 in: one condition writes one packet row, never a
roll-up plus an item.

**Landed 2026-10-02** (846e055cd). `grocery/review-adjudication-lib.ps1` runs the three ruled adjudications at
send-alert's review route; the five types write one row per condition to `grocery/out/review-packet.json` (gitignored)
and only an unexplained crown change or out-of-band move on a live cell still queues. dc03c3 is folded in (one condition,
one row; the roll-up writes none). triage-due lists packet rows as Class C/D work; the census prints page days against the
bar and per-type row parity. Baseline: the five types queued on 14 of the 14 days 2026-09-19..2026-10-02. **Bar window
2026-10-03 to 2026-10-16, read 2026-10-17.** One reading Brad may want to narrow: a SANITY "cheapest moved" new price flag
counts as a crown change, so an unexplained one still queues (new price flags alone queued on 6 of the last 14 days).

### Phase 5. Chain data flow (needs D2; one or two sessions)

1. `lib/board-pin.ps1`: the run pins one comparison generation at its start; guards, the feed export, the post
   builder and the deals page read the pin. A consumer that reads a different generation is a hard fail.
2. A declared input/output list per chain step, and a gate that fails when a step reads a file whose writer runs later
   in the chain (c6bafd's shape: the feed export reads recipe costs before top5-weekly writes them).
3. **Bar:** over 14 days, 0 runs where the post, the feed and the guards name different generations, and the feed's
   recipe fields equal top5-weekly's on 14 of 14 days. Fixtures: the c6bafd order as MUST FIRE, today's correct order
   as CLEAN TWIN.
4. 2bcd10 stays with the bot-dedicated-checkout plan; this phase does not duplicate it.

**Landed 2026-10-02** (f3b1b47da). `lib/board-pin.ps1`: the chain pins one board generation after its last board
writer and before any consumer; guards, export-feed, publish-deals-page, build-deals-page, build-store-guide,
publish-store-guide, send-price-alerts, build-sams-data, build-friday-email and capture-run's deferred post read the pin
inside a run and behave as before outside one; a consumer handed another generation stops with BOARD-PIN MISMATCH. On a
quarantine day the pin re-derives the verified board, so the post carries the held cells (1d4206). `ops/chain-steps.json`
declares 26 steps and `lib/chain-step-order.ps1` (inside check-ad-cycles' self-test) fails a read before its writer; on
today's chain it fired three times: c6bafd, and the daily export reading `v2-perserving.json` before compute-v2 writes it
(the 602457 fix had not closed per_serving). A second export after top5-weekly, on the not-blocked publishing path only,
fixes all three. It does NOT close 871301 (its 8 sites are outside the chain steps), which stays in the queue.
**Bar window: the 14 daily runs 2026-10-03 to 2026-10-16, read 2026-10-17** with
`powershell -File lib\board-pin.ps1 -Report -OutDir grocery\out -Days 14`: diverged=0 and recipe_equal 14 of 14.
**Residuals owned by this phase (D3: recorded here, not minted):** price history is banked from the board before guards
can quarantine it; recipe-overlay reads the board before a quarantine; compute-v2 never sees quarantine-held ingredient
prices; guards' delegated audits, recipe-overlay and build-sale-windows are not wired to the pin (they read the pinned file
only because it is also the newest). Each was printed by the build on every run; none is measured yet.

### Phase 6. Traps into gates (one session)

1. A ratchet on `@(... | ConvertFrom-Json)` and `@(Get-...)` inline wraps (rule og-08), mark set at today's 90 sites and
   only allowed to fall; the existing `audit-list-array-wrap` is the exemplar to extend rather than a new gate (CLAUDE.md:
   new machinery must pay for itself).
2. A static check for self-tests that assert an upper wall-clock bar or a CPU share (rule og-36 is judgement today),
   with c12baf's reaper case as MUST FIRE.
3. **Bar:** 0 gate refusals attributed to box load over 14 days, from the push ledger.

**Status 2026-10-02: LANDED (5754a876d).** What changed against the steps above, and why:
- Step 1 is held at ZERO in the existing `audit-readjson-inline-wrap.ps1` under `ops/`, not ratcheted. Read off the AST, the "90
  sites" were 7 in 775 scripts: the text regex also matched comments and `@((x | ConvertFrom-Json))`, which unrolls.
  Five of the 7 read a top-level array and were fixed in the same change (`build-arrivals-docket` had never loaded a
  commodity label: one key holding all 599 ids); two are deliberate MUST FIRE probes, now marked. With no backlog a
  ratchet's mark is 0, which is this same gate with a baseline file to keep. The `@(Get-...)` shape (rule og-08) is NOT
  held: 711 single-command wraps, 518 calling something other than a built-in cmdlet, 36 whose callee name returns with
  a leading comma somewhere in the tree. Names collide across files, so a count mixes the correct idiom with the trap.
  It needs per-file dot-source resolution; that is open.
- Step 2 is a new `ops/audit-selftest-load-bars.ps1` (no existing audit fitted), a ratchet at 1 site
  (`meal-prep/test-scale-hardening.ps1`, a live-network 404 held under 5 s). Rule og-36's tag now names it.
- c12baf is fixed at source: the reaper's MUST FIRE reads a fixed share through a new `-ReadCpu` seam; its 50% bar stays
  on the pure `Get-ReapVerdict`.
- ae8b7a part (b): test-match-lib reads BLIND (rc 3, `blind=matcher-load`) when its only red is still-blind names and
  more blind looks recovered on the re-look than stayed blind; test-auditors counts that as a SKIP. Part (a) stays open.

**Bar window: opens on the day this lands on origin/main and closes 14 days later. Baseline, the 14 days before
2026-10-02: 4 refusals attributed to load, all `ops\reap-runaway-processes.ps1` (2026-09-27, 09-29, 10-01, 10-02; the
spinner's share read 46.9, 43.8, 48.4 and 48.4 against 50).** How to read it:
- The ledger is `%LOCALAPPDATA%\ThriftyCrew\push-ledger\pushes-<yyyy-MM-dd>.jsonl` (`push-ledger.ps1` under `lib/`), one file a
  day, outside every checkout. The counted rows are `event = hook-refused`. Each names `gate`, `rc`, `blind`,
  `local_sha` and `log`, the gate log the pre-push hook keeps for a refusal.
- A refusal is ATTRIBUTED TO LOAD when either (1) its `blind` token is `no-gate-worker-slot`, or (2) the FAIL line in
  its `log` is a case whose subject is the box rather than the code: a CPU share, a wall-clock bar, or a match-lib
  still-blind name. A case of kind (2) must also pass when its gate's self-test is re-run at rest at the same
  `local_sha`. Every other refusal is the code's and is not counted.
- NOT COUNTABLE, stated: push-main's own `refused-gate-red` rows (162 since 2026-09-12) do not name the failing gate,
  so this bar cannot see them. A `gate` field on that row is the fix; it is open.

### Phase 7. Capture coverage (after R11 and the 3b decision)

The 86-day rotation stays as ruled. The paced 3b trial answers its two COULD NOT VERIFY criteria, then Brad rules
build or not; separately, Brad rules whether a sale cell with no everyday fallback may move its term to the front of
the rotation (a priority change inside the same 7-a-day budget, not a bigger budget). e40f92 and e7f9b9 close
when Family Fare everyday rows land for their cells, or when the cells are ruled not carried.

**Brad's rulings, 2026-10-03** (chat, AskUserQuestion; each recorded as asked):
- **R7.1 Family Fare priority:** (RULED A by Brad, 2026-10-03, "Yes, jump the queue (Recommended)") a sale cell with no
  everyday fallback moves its term to the front of the Family Fare rotation, inside the same 7-a-day budget.
- **R7.2 3b trial:** (RULED A by Brad, 2026-10-03, "Run the trial (Recommended)") run the paced catalog-walk trial that
  answers its two COULD NOT VERIFY criteria; Brad then rules build or not.
- **R7.3 Hy-Vee gaps:** (RULED A by Brad, 2026-10-03, "Measure first (Recommended)") measure whether Hy-Vee carries the
  five items at an everyday price before any change to its pull.
  **Measured 2026-10-03** (`design/MEASURE-hyvee-everyday-gaps-2026-10-03.md`): all five are CARRIED-EVERYDAY at Omaha
  #02 (storeId 1466), 5 of 5 judged, 0 could-not-look, each with a plain product the store answered at a regular price
  (15 searches through discover-hyvee's own request, 42 lookups through the pull's own GraphQL body). The gap is ours,
  in three places: the pull re-reads known product ids only and none of the five has a Hy-Vee row or a Hy-Vee
  `product-urls.json` entry, so its own dry run prints "sale fallbacks owed 5, 5 in today's plan, 0 promoted" with no
  reason; `audit-sale-fallback`'s terms-attempted check returns true for every Hy-Vee gap, because Hy-Vee's
  capture_terms are product keys and the check answers true when it knows no term; and discover-hyvee already
  docketed four of the five with product ids, but its docket reaches no pull, while frozen-cauliflower-rice has no
  search term at all. Recommendation, for the next ruling: admit one plain everyday product id per item through the
  discovery docket into `product-urls.json`, add a term for frozen-cauliflower-rice, make the pull name a fallback it
  cannot ask, and make the audit report UNPROVEN where it cannot test. Nothing is recorded not-carried.
- **R7.4 (step 8) liquid-ounce sizes:** (RULED A by Brad, 2026-10-03, "Give each a density (Recommended)") each of the 11
  oz-unit commodities whose rows the row contract would refuse for a fluid-ounce size declares a sourced density, so the
  sizes convert and no cell empties. No density is typed from memory: each carries its source.

**2026-10-02.** The detective half landed with this status update: when every escalated
sale cell is owned and asked, the alert now says "their capture has not found one" instead of "NO ONE IS WORKING THEM",
registered as sale-no-fallback-worked. Phase 0 found the family is wider than this phase: 5 of the 8 cells that day were
Hy-Vee, which the Family Fare rotation does not explain, so a third call is waiting with the other two in
`design/ready-for-brad/weekly-root-families-phase-7.md`.

**R7.2, 2026-10-03: RULED "Run the trial (Recommended)"; PREPARED, NOT RUN.**
- The trial is `design/TRIAL-familyfare-catalog-walk-paced-2026-10.md`. Its rubric was written before any request:
  - C2 is MET when, after a 30-page walk in the same window, 20 of 20 rotation searches answer HTTP 200 with rows.
  - C3 is MET when at least 95% of the id-bearing everyday rows are found in the walk.
  - C1, re-measured as the precondition, is MET at 99% of `total`.
- The instrument and scorer is `grocery/trial-ff-catalog-walk.ps1`, with a 34-case hermetic self-test.
- No browser is needed. Family Fare capture is token-less PowerShell HTTP, so the ruling note's "needs a browser
  session" does not hold.
- Open: land the script, then the lead registers the scheduled-session prompt in the trial doc as one task. It fires
  hourly from 20:05 to 01:05 on one night, at most one window a fire. Then Brad rules build or not.

## 4. What finished looks like

- The remainder plan's steps 8, 9 and 11 read DONE with their bars met, and this plan's phases do too.
- The weekly queue holds only items no ruled step owns, and the stalled-ruling page has not fired for 14 days.
- The census, read with denominators: quiet days over 14 days, returns30, and the share of alerts per family,
  before and after. A number that moved is reported with how far and over how many days, not as improvement.

## 5. Not in scope

- Re-deciding any 2026-09-10 ruling or its bar. This plan schedules and connects them; it does not change them.
- The knowledge store item (D4) and anything outside `grocery/` and its gates.

## Knowledge consulted

- Searched "systemic recurring alerts root cause prevention" (knowledge-search --estate). Used:
  - `reliability-craft/rca-and-chaos.md` section 2: corrective actions come in three kinds (preventive, detective,
    responsive) and "a list containing only the first is incomplete". Phases 2 to 5 are preventive; Phase 1's
    stalled-ruling page is the detective action this program lacked.
  - `data-quality-craft/diagnosing-a-failure.md` section 3: "Stopping at the cause instead of the class. Fixing the
    one..." The family table is the class level above each item's own root cause.
  - `reliability-craft/toil-runbooks-and-recovery.md` section 1: toil is repetitive, manual, automatable and creates no
    lasting value; re-diagnosing the same family at full price each week fits it.
- Searched "attribute recurring alerts to root families" (`--estate-root C:/Codex/ThriftyCrew`). Used
  `reliability-craft/MAP.md` section 5, "do not declare resolved on the alert going quiet", now the close rule in
  section 3. Nothing else new beyond the three files above.
- Searched "classification bar attribution coverage threshold" (knowledge-search --estate). Used: memory
  `ff-term-budget-is-quarterly-by-design` ("The Family Fare pull buying 7 terms of 602 per day is DELIBERATE, not a
  throttle defect"), which corrected family 4; rule og-13 (what a threshold does when its producer stops), now in
  Phase 1 step 3.
- `experiment-craft/analysis-preflight.md`: items 2 and 3 (denominators, bars before the run) drove the exact counts
  in section 2 and the Phase 0 and Phase 1 bars; item 8 (a delegated finding is an input) is why the family table is
  marked as the orchestrator's reading until Phase 0 measures it.
- `PLAN-zero-alert-days-remainder-2026-09-24.md` (design/): the rulings and bars for steps 8, 9, 11, R18, R11 and 3b,
  carried here by reference and quoted verbatim where restated.
- `.claude/rules/ops-and-gates.md` og-05 (fixture labels), og-06 (at-bar and past-bar cases), og-08 (inline array wrap),
  og-11 (ratchets only fall), og-36 (no upper wall-clock bars), og-47 (land through push-main).
- `.claude/rules/measurement.md`: bars written before the run, rates with denominators, "a number that moved is not a
  number that improved".
- memory `triage-cost-controls`: residual owners and the weekly lane (the basis for D3).
