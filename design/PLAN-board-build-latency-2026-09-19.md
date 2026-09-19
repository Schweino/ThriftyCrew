# PLAN - A board rebuild in 1-2 minutes: what the 37 minutes is, and the two design faults behind it

**Status: PROPOSAL, awaiting Brad's go on the phase order. Nothing here is built.**
Brad, 2026-09-19, after watching a republish take over half an hour: *"There is absolutely no need to
read every capture. A capture is a one-time job to update a database. That's it."* and *"This should
take like 1-2 minutes. We are doing it wrong."*

## 1. The measurement, and how to repeat it

Three full runs of `check-ad-cycles.ps1 -NoPull` on 2026-09-19, from the chain's own log:

| run | total | ship path | advisory fan-out |
|---|---|---|---|
| 09:17 (the daily) | 4,174s | 805s | 438s |
| 16:59 (rebuild 1, guards blocked the publish) | 2,184s | 799s | 417s |
| 17:48 (rebuild 2, published) | **2,211s (36.9 min)** | 726s | 354s |

The harness is committed: `ops\report-chain-stages.ps1` (`-Date`, `-Run`, `-Top`), which derives per-stage
wall clock from the log's own timestamps. It is UNSOUND as a profiler by construction - it charges a
silence to the stage that spoke last - and says so in its header. Its numbers for the 17:48 run:

| seconds | % of run | stage |
|---|---|---|
| 631 | 28.5% | prune-intermediates -> test-auditors (the estate's unit suite, inside a board publish) |
| 354 | 16.0% | the INSPECT advisory fan-out, 34 audits over 8 workers |
| 266 | 12.0% | multipack-repair |
| 201 | 9.1% | sale-fallback |
| 109 | 4.9% | sale-windows |
| 104 | 4.7% | free-rotation |
| 61 | 2.8% | **guards - the invariants that can actually stop a bad price** |
| 52 | 2.4% | derive-links-from-prices |

2,093s of the 2,211s is attributed. Producing the artefact is the small part.

## 2. The two faults

**Fault A - the data path re-derives everything, every time.** `compare-deals.ps1` reads the whole
90-day capture window on every build: 307 files, 794 MB, 928,034 product rows, matched against
`commodities.json`'s 71,693 exclude patterns (2,430 distinct; 211 patterns appear in 100+ commodities,
accounting for 66,775 of the copies) to produce ~3,000 board cells.

**The database Brad describes already exists and is already current.** `graph/sqlite/graph.db`
`price_observations`: 59,338 rows, 2026-07-14 to 2026-09-19, 20,777 written on 09-19 alone, carrying
commodity, store, price, unit price, size, `observed_at`, `source_file`, an adjudication status and a
basis-plausibility flag. In the last 90 days it holds 31,279 `include_hit` rows over **3,508 distinct
(commodity, store) pairs** - the board is ~3,200 cells. The board simply does not read it.

This was diagnosed a month ago and stopped for a decision: `design/PLAN-parity-road-2026-08-20.md`
("Awaiting Brad's go on the phase order"), with `graph/eval/board_parity.py` as the gate - agreement
0.899, coverage 0.876, 289 conflicts and 405 uncovered cells, each assigned a cause, phases P0-P5.
Neither file has been touched since 21 August.

**Fault B - the publish path re-verifies the whole estate, synchronously.** A price publish runs the
unit suite (631s), 34 advisory audits (354s), and four corpus-wide repair sweeps (628s) before it is
done. None of those decide whether today's board is safe; `guards` does, in 61s. The consequence is not
only latency: a mid-day correction costs half an hour, so corrections get batched, deferred, or skipped,
which is how a thin board sat live from 13:10 to 18:30 on 2026-09-19.

## 3. The phases, cheapest first. Acceptance bars are stated BEFORE the work

| phase | work | acceptance bar, written now |
|---|---|---|
| **L0 (done)** | `ops\report-chain-stages.ps1`, committed with fixtures | attributes >= 90% of a run's wall clock. Measured: 2,093 of 2,211s (94.7%) |
| **L1** | Split the publish path: `guards` + render + upsert stay inline; the unit suite, the advisory audits and the repair sweeps move to their own schedule or to an async pass over the PUBLISHED artefact | a publish that changes only prices completes in <= 180s wall clock, measured the same way, with guards still run inline and no audit deleted - each must be running somewhere and named in `expected-automations.json` |
| **L2** | De-duplicate the excludes into `global-exclude-lib.ps1`'s shared list; per-commodity lists keep only what is genuinely theirs | the board is byte-identical before and after on the same inputs (this is the gate, not a count), and the pattern total falls from 71,693 to under 6,000 |
| **L3** | P0+P1 of the parity road: scope the gate to staple rows, then make "newest surviving row per (store, product)" the crown rule | `board_parity.py` agreement >= 0.94 at coverage >= 0.94, both reported separately as that file already insists |
| **L4** | The cutover: `compare-deals` reads `price_observations` for candidate rows instead of walking `out\regular\*.json`; the capture files stay as the audit trail and a full re-derivation stays available as an explicit command | `board_parity.py` >= 0.99 agreement, AND a rebuild from the database reproduces the file-derived board cell for cell on the same day's inputs, AND a board build completes in <= 120s |

L1 is the big latency win and touches no pricing rule. L2 is the correctness win: two of the four
blockers on 2026-09-19 (almond butter matching a baby-food pouch; honey mustard mixing jars with
dressings) were the duplication class. L3/L4 are the model Brad described and need his phase order.

## 4. What must not be lost, and the risk to respect

- **Full recomputation stays.** It is what lets a rule change re-apply to history, and this estate has
  caught real defects because of it. L4 makes it an explicit command rather than the daily default.
- **The database must stay strictly DERIVED and rebuildable from the capture files**, with the parity
  check above as a standing gate. This estate already paid for prices and links being two pipelines for
  one fact (`derive-links-from-prices.ps1`'s header is the account); a prices table that becomes a
  second source of truth would be the same mistake at a larger scale.
- **No audit is deleted by L1.** Moving a check off the publish path and forgetting to schedule it is
  how a guard stops guarding silently; the bar above requires each one to be named in the automations
  register.

## Knowledge consulted

- `database-craft/applies-here.md` 1-2 - the estate's own SQLite inventory and row counts; this is where
  `price_observations` (26,740 rows when that was written, 59,338 today) is recorded, and it is what
  showed the table already existed rather than needing to be designed.
- `data-quality-craft/moving-data-in-flight.md` 5 - full versus incremental loading: incremental appends
  what changed and is what accumulates a history, which is the L4 ingest shape.
- `concurrency-craft/applies-here.md` 30 and `concurrency-craft/distributed-coordination.md` 14a -
  idempotence is decided by the data structure, not the call site: an upsert keyed on (store, product,
  observed_at) is replayable, an append is not. L4's ingest must be the former so a re-ingest of a
  capture file is harmless.
- `database-craft/indexing-strategy.md` - an index is a bet paid on every write; the L4 query is
  "cheapest row per (commodity, store) within a window", so that is the index to measure, not to assume.
- Searched "materialized view", "sqlite upsert", "incremental ingest", "parity check two
  implementations": nothing applicable - the store holds no section on any of them.
