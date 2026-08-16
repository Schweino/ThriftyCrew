# PLAN: Recipe Hunter Sustainability - Every Measured Burn, and What Makes It Stop

Date: 2026-08-16 (full rewrite, same day, after the wave-1 double NO-GO and the live-site unbid
finding). Status: PROPOSED, awaiting Brad's direction.
Prereq reading: design\PLAN-recipe-hunter-v2-2026-08-15.md section 2.4, then
design\PLAN-recipe-hunter-v2.1-2026-08-15.md section 5.

## 0. The ledger, stated honestly

Two runs of `hunt-2026-08-15-lowcarb-100`: **~28M subagent tokens, ~1,300 agent invocations, 0
recipes published.** What the money actually bought:

- 24 fully built specs (2 audit-clean today, 19 salvageable the moment bids are wired), 47
  transcriptions, 38 mappings, 19 QA verdicts - all durable on disk and reusable.
- **Twelve distinct defects found**, eleven in the orchestrator and one in an estate gate, each now
  fixed or precisely characterized (section 3).
- A live-site defect that **predates this run**: 4 published recipes silently pricing large
  ingredients at $0.00. The run's auditor is what exposed the class.

That is not nothing. It is also not a price worth paying twice. The pattern across every burn is the
same: **defects were discovered at the most expensive gate that could catch them instead of the
cheapest, and nothing the system learned was retained anywhere a later run could use.** Fixing those
two facts is this plan.

## 1. Root causes (fix these, not their symptoms)

| # | Root cause | What it cost here |
|---|---|---|
| R1 | **The orchestrator is an untested artifact.** Every `.ps1` in this estate carries a self-test; the workflow script that spends the tokens carries none. Eleven of the twelve defects lived there | Most of the 28M |
| R2 | **No memory between runs.** Rejections, mappings, domain failures, fetched pages - all forgotten at run end | 48% dupe churn, re-fetches, re-rulings, forever |
| R3 | **Gates placed late.** Cost-soundness is first checked by the batch auditor - the single most expensive agent - after write, spec and QA are already paid for | 10 recipes waved before one unbid ingredient was challenged |
| R4 | **Agent claims taken on faith.** A repair agent reported success having changed nothing; the only check was a second full audit | One whole re-audit cycle |
| R5 | **No cost accounting.** v2.1 section 5.2 requires per-stage token totals; it has never once run, so every ranking (including this document's) is an estimate | Cannot tell which fix mattered |
| R6 | **Context priced wrong.** Whole pages fetched to reject on a title; a 110KB digest loaded whole to answer a 1KB question; constant rules re-shipped per call | Millions, run after run |

## 2a. MEASURED, 2026-08-16. This section supersedes the estimates below.

`pipeline\lane-tokens.ps1` (built this day) attributes every subagent transcript to a lane by reading
the `-LaneName` out of its dispatch prompt, and sums usage. Run 2 (`wf_11382034-6fd`), 1,335
transcripts:

| lane | agents | total tokens | share |
|---|---|---|---|
| **hunt** | 245 | **325,543,422** | **43.3%** |
| **select** | 333 | **242,157,676** | **32.2%** |
| map | 627 | 98,727,543 | 13.1% |
| write | 15 | 36,282,000 | 4.8% |
| unknown | 37 | 24,280,307 | 3.2% |
| extract | 58 | 12,127,231 | 1.6% |
| price | 10 | 10,653,000 | 1.4% |
| qa | 10 | 1,994,125 | 0.3% |
| **TOTAL** | **1,335** | **751,765,304** | |

**Read this carefully before acting on it.**

1. **hunt + select = 75.5% of all tokens.** The front end is not one waste among several; it is
   three quarters of the bill. Every front-end item below (D1, D2, D3, C1, C3) aims here.
2. **This total counts cache reads as input**, which the workflow's own 16.1M "subagent tokens"
   figure does not. Cache-read tokens bill at a lower rate, so 751M is NOT 751M at full price - it is
   a volume measure of context moved, and the gap between 16.1M and 751M IS the repeated-context
   problem (W4/W5) stated in its own units. Do not quote 751M as a cost.
3. **W1's ranking was wrong.** ~10M of failed-call overhead is ~1.3% of this accounting, not "most of
   the run". The circuit breaker was still worth building - it stopped an unbounded loop - but it is
   not the big lever, and this plan said the measurement would win.
4. **map at 627 agents for 13.1%** is the cheapest-per-call lane doing the most calls. Its
   micro-batching is working; leave it alone.
5. **qa at 0.3% and price at 1.4%** are not worth optimizing. Any effort spent there is misallocated.

The `-Slugs`-scoped `hunt-run.ps1 -LaneSummary` gives the call/item counts from the lane log for a
live run; `lane-tokens.ps1 -TranscriptDir <dir> -PerRecipe <n>` gives the token figures and the
per-recipe cost against v2.1's 200-250K target.

## 2. The rule: measure first, and the measurement wins

**I1 - per-stage token accounting - precedes everything else.** Extend `hunt-run.ps1 -Lane` (which
already records every dispatch) with `-InputTokens` / `-OutputTokens`, stamped by the orchestrator
from each Agent result as it arrives, so `lane-log.jsonl` is the ledger and does not depend on a run
surviving to its final phase (none has). Summary output: per stage - calls, input, output, mean,
share of total.

First questions it must answer: (a) did failed-call overhead (W1) dominate, and is it gone now that
the circuit breaker exists? (b) does the audit's measured share still sit near 31%? Re-rank
everything below against the answers.

## 3. Complete waste inventory

Bugs first - each is a one-time burn UNLESS the orchestrator stays untested, which is why R1 leads
the build order. All eleven orchestrator defects are fixed in the current script; none is frozen as
a fixture yet.

| # | Defect | Burn |
|---|---|---|
| B1 | Pricing built per-recipe, discarding the queue's cross-term dedup | Run 1 restart |
| B2 | Hunt -> dedup -> decide run as awaited barriers, lanes mutually idle | Run 1 restart |
| B3 | Pool batching instead of per-candidate streaming (8-10 min to first flow) | Restart |
| B4 | Price lane waited for a full batch of 10, contradicting plan 2.4's own snapshot-and-go loop, plus the deadlock valve that wait required | Restart |
| B5 | Null agent result treated as an explicit rejection (14 false rejections reported) | Diagnosis + repair |
| B6 | Retry budgets keyed by batch shape, never saturating: **657 failed calls, ~10M tokens, zero progress**, died on the 1000-call cap | ~10M |
| B7 | `"pass"` compared against `'PASS'`: 12 genuine passes read as failures, each burning a spurious repair + re-QA; no wave could close | ~1M+ |
| B8 | `-Terms 'a,b'` bound as ONE composite string: recipes park forever, silently, while their ingredients sit CARRIED | 2 casualties + diagnosis |
| B9 | WIP limit + closed lanes = unwakeable sourcers (caught before it ran) | - |
| B10 | Double NO-GO leaves 10 recipes stranded in `waved` with no exit; plan S8's trim path was never implemented, so 2 audit-clean recipes sit hostage to 8 blocked ones | 10 recipes idle |
| B11 | Repair claims unverified: agent reported repairing specs it never touched; discovered only by paying for a full re-audit | 1 re-audit |
| B12 | **Estate gate inversion** (`build-v2-spec.ps1:201`): a bid that resolves badly THROWS; an ingredient with NO bid prints a console note after the spec is already written. The worse defect ships; the lesser one blocks. Result: 23 specs with $0.00 ingredients, **4 of them LIVE** (keto bun 1,320g; Korean rice cakes 1,300g; bulgur 957g; sumac) | 10 waved recipes + a live-site correctness hole |

Structural waste - recurs every run until built away:

| # | Waste | Evidence | Confidence |
|---|---|---|---|
| W1 | Failed calls ship full prompts | 657 of 1,000 calls, ~10M tokens | High; **fixed** (breaker + per-slug retries) - I1 confirms |
| W2 | Pages fetched then discarded | 11 searches / 6 fetches per few candidates; a recipe page is 20-50K tokens | High |
| W3 | Re-deciding known duplicates | **44 of 91 (48%) `rejected-dupe`**, zero persistence | High |
| W4 | Digest loaded whole | 111,942 bytes x ~220 reads; 221,784 cache-read tokens observed on one agent | Medium (prompt caching recovers part) |
| W5 | Constant prompt text re-shipped | `SHELL`+`RULES` on ~1,000 calls; variable text interleaved defeats prefix caching | Medium |
| W6 | The audit | 31% of tokens (v2.1 measured); whole-wave re-audits after recipe-local fixes | High |
| W7 | Same page fetched twice (sourcer, then extractor) | 47 transcriptions | High, small |
| W8 | Link rot destroys finished work | 2 recipes died on 404s AFTER successful sourcing | High, small |
| W9 | Stable mappings re-derived per recipe; registrar rulings re-litigated | Mapper transcripts | Medium |
| W10 | Domain failures re-learned | `thespruceeats` blocked in BOTH agent prompts yet sourced from anyway (404); `themediterraneandish` 404'd and joined no list | High |
| W11 | Cold restarts re-buy sourcing | Two full restarts before `resumeFromRunId` became practice | High; fixed by practice, not by code |

## 4. Improvements, grouped by the root cause they kill

### Group A - R1: the orchestrator becomes a tested estate artifact

**A1. Codify it.** The orchestrator moves out of a session scratchpad into the repo
(`meal-prep\pipeline\hunt-orchestrator.js`), versioned and reviewed like every other load-bearing
file. A fresh session extends a tested artifact instead of re-deriving one from prose -
re-derivation is where B1-B4 came from.

**A2. Self-test with a fake agent().** A harness that injects scripted agent responses and asserts
lane behaviour, exactly the estate's must-fire pattern. Every bug above becomes a fixture the same
day it is found, per the standing rule. Minimum set: null result is STUCK never rejected (B5);
retries keyed per slug (B6); verdicts matched case-insensitively on first token, and "NO-GO" never
parses as "GO" (B7); a comma inside a term refuses (B8); breaker trips on consecutive failures and
every lane unwinds with no waiter left hanging (B6/B9); double NO-GO trims per S8, never strands
(B10); a repair claim with untouched files refuses the re-audit dispatch (B11); channel
close-cascade terminates with an empty hunt lane (drain mode).

**A3. Postconditions on agent claims (B11).** After any dispatch whose job is to change files, the
orchestrator mechanically verifies the claimed artifacts changed - mtime/hash of the named specs -
**before** paying for the expensive next stage. The re-audit that exposed B11 did this check itself;
doing it in the orchestrator costs nothing and saves the re-audit. Same idea as wave-publish P1b
(audit older than a spec edit refuses), applied to every "I changed X" claim.

**A4. Implement S8's NO-GO handling (B10).** On NO-GO: blocking slugs leave the wave - to repair
(once) or `rejected-audit` - and the **trimmed manifest re-audits**, scoped per v2.1 B2. Audit-clean
recipes never sit hostage to blocked ones; nothing can strand in `waved`. Requires A5.

**A5. Machine-readable per-slug verdicts from the auditor.** The wave-1 report already contains a
per-slug table; formalize it (one line per slug: `slug | GO/BLOCK | reason-class`) so A4's trim is
mechanical rather than parsed out of prose. The wave verdict stays the wave's; the per-slug lines
are what the orchestrator may act on.

### Group B - R3: gates at the cheapest point that can host them

**B-1. Fix the B12 inversion.** `build-v2-spec.ps1` throws on an unbid scaler ingredient exactly as
it throws on CHEAPEST-FALLBACK, listing the offending items and pointing at `db\ingredients.json` /
`no-board-price-ok.json`. Must-fire: a spec with one unbid line refuses to build. Clean twin: fully
bid spec builds. Allowlisted no-board bids keep working - that mechanism already exists and is the
sanctioned escape.

**B-2. Check bids at the MAPPER, before write is ever paid.** The mapper already resolves every
ingredient; it also declares, per ingredient, whether a bid exists. No bid and no allowlist entry ->
the recipe holds at `mapped` with a named follow-up (wire the bid, or registrar ruling) instead of
flowing to write/spec/QA and dying at the audit. The same fact, checked ~200K tokens earlier.

**B-3. Standing sweep: `audit-unbid-ingredients.ps1`** over `db\recipes` - the check that found the
4 live offenders, kept as a permanent guard with fixtures and wired into wave-publish's preflight so
the class cannot re-enter by any path (hand-edit, migration, future bug).

**B-4. Scoped-re-audit gate (W6).** v2.1 B2's rule, enforced: a re-audit dispatch whose scope is
whole-wave when only recipe-local specs changed since the last GO is refused; a shared-data change
REQUIRES whole-wave. Care: this gate may only ever narrow re-verification of provably unchanged
bytes. Must-fire: a cost-basis change refuses a narrow scope.

### Group C - R2: memory between runs

**C1. Rejected-candidate ledger** (`meal-prep\db\considered-dishes.json`). One row per dish ever
ruled on, keyed on normalized identity (`protein|method|sauce-family`), carrying verdict, reason,
dupe_of, ruled_by, run, date. Written by the decider only (already the single writer of selection
state). Read by sourcers BEFORE any fetch, by adjudicators as prior art. **Advisory-only until the
false-positive rate is measured** on a hand-checked sample; the 48% dupe rate then compounds away
run over run. Must-fire: a previously-rejected dish is surfaced. Clean twin: a novel dish is not.

**C2. Ingredient-resolution cache** (`meal-prep\db\ingredient-resolutions.json`):
`term -> {item_id, bid_exists, evidence, ruled_by, at}`. Mapper consults before reasoning; registrar
rulings recorded so they are never re-litigated. Identity only - **never price**, which stays on the
board. Invalidated by any registrar ruling that changes a commodity id.

**C3. Source-domain ledger** (`meal-prep\db\source-domains.json`):
`domain -> {status: reliable|unreliable|blocked, fetch_ok, fetch_fail, last_404, has_jsonld, note}`.
Appended automatically on every fetch outcome - the pipeline learns from its own failures instead of
waiting for a human to edit prose. Replaces the duplicated hardcoded lists in `recipe-sourcer.md` /
`recipe-source-qa.md` (identical today, unsynchronized by anything). One 404 makes a domain
`unreliable`, not `blocked` - a single failure is a fact about one URL; only a pattern earns
`blocked`, with counts recorded so the judgment is auditable. `has_jsonld` feeds D1.

**C4. Page cache.** Sourcer stores the raw fetched body content-addressed by URL hash; the extractor
transcribes from cache, re-fetching only on miss. Kills W7 and W8 (the two 404-killed recipes had
already been read successfully). Transcribing cached bytes of the page is still transcribing the
page; transcribing the sourcer's *description* of a page remains forbidden.

### Group D - R6: context priced right

**D1. Fetch discipline.** (a) Reject on search snippets for dish-identity dupes before any fetch -
identity is snippet-visible, nutrition is not, so snippets may only reject duplicates, never rule on
the band. (b) Prefer JSON-LD `Recipe` blocks (nutrition, ingredients, instructions at a fraction of
page weight, and more reliable than prose-reading a rendered page); one helper
`fetch-recipe-jsonld.ps1` serves sourcer, extractor and cache; a JSON-LD-vs-page disagreement is a
reported finding, never a silent preference. (c) Scoped extraction where the fetch tool supports it.

**D2. Query the catalog, never load it.** `find-similar.ps1 -Name -Protein [-Top 5]` returns the
nearest entries (~1KB) in place of the 110KB digest read. Sourcer and adjudicator prompts stop
naming the digest path entirely.

**D3. Saturation guidance.** Derive `saturation.json` at run start - live-recipe counts per
(protein x method x sauce-family) - and put the crowded regions in the sourcer brief: "this lane
holds 14; bring another only if distinct on a named axis, and name it." Attacks the 48% at source
(five creamy pork-chop skillets and four creamy chicken skillets were fetched and adjudicated this
run before dying). C1 remembers dishes; D3 describes regions; they compose.

**D4. Prompt architecture for caching.** Move `RULES` and other constants into the agent definitions
under `.claude\agents\` (loaded once per agent type); order remaining prompts
stable-prefix-first, variable-suffix-last, so provider-side prefix caching actually lands. Measured
against I1's mean-input-per-call, behaviour unchanged.

**D5. Resume as standing practice (W11).** A stopped run is resumed with `resumeFromRunId`, never
cold-restarted; drain mode (already built) is the standing shape for clear-the-pipeline work.
Written into SKILL.md so the practice survives this session.

### Group E - model tiers, as measured experiments only

Held OUT of the build order; each trades quality and runs as its own experiment after I1 provides
baselines. (a) Sourcers to Sonnet-medium with their dedup stripped to a crude prefilter - the
authoritative rulings already live downstream in adjudicate/decide, which overruled sourcer KEEPs
repeatedly this run; acceptance: dupe and band-miss rates hold while cost drops. (b) The extractor
is the only cheap-model candidate among the Fable pins, because source-QA independently re-checks
its output. The audit tier (batch-auditor, post-publish-reviewer) is **not** an experiment
candidate - it is the layer that caught B12, caught the lying repair, and returned two correct
NO-GOs this run.

## 5. Cloudflare: local first, lift later

The token savings above are interface facts, not hosting facts - "query instead of load" and "cache
instead of re-fetch" save the same tokens from a local JSON file as from D1 behind a Worker. Local
ships this week, needs no auth, adds no network failure mode, and captures ~90% of the win.

The real Cloudflare case: durability (C1/C2 are institutional memory), one deployment story (the
site already serves from that stack), and reachability if runs move to scheduled cloud agents.
Every consumer above calls a *script*, never a file path, so the lift is a wrapper swap: D1 tables
for `considered_dishes` and `ingredient_resolutions` (small, write-rarely, read-often), R2 for page
bodies (content-addressed, so identical URLs dedupe free), a Worker with `GET /similar`,
`/considered`, `/resolution` and token-authenticated POSTs restricted to the decider and mapper
roles. **Non-negotiable: wrappers fail soft.** A Worker timeout returns *unknown*, never *not a
duplicate* - could-not-look is never a clean bill, same as the store rule.

## 6. Build order

**Phase 0 - correctness, before any efficiency work:**
1. B-1 (unbid throws) + B-3 (standing sweep), same commit, fixtures included.
2. Wire bids for the 4 LIVE recipes (keto bun, Korean rice cakes, bulgur, sumac), re-cost,
   republish through the sanctioned path. Live pages are understating cost today.
3. Wire bids for the 19 blocked new specs; rebuild via build-v2-spec (which now enforces).
4. A4+A5 (S8 trim + per-slug verdicts): un-strand wave 1 - the 2 clean recipes publish, the 8
   return to the pool pending their bids.

**Phase 1 - measurement:**
5. I1. One drained wave with a per-stage token table. Re-rank below against it.

**Phase 2 - the orchestrator:**
6. A1+A2 (codify + fixtures for all of B1-B11).
7. A3 (postconditions).

**Phase 3 - front end, pending I1's numbers:**
8. D2 (query-not-load).  9. D1+C3 (they share the fetch path).  10. D3 (saturation).
11. D4 (prompt/cache architecture).  12. C4 (page cache).  13. C1 (rejected memory, advisory).
14. C2 (resolution cache).

**Phase 4:**
15. B-4 (scoped re-audit) - **sooner if I1 shows the audit dominating, which v2.1's 31% suggests.**
16. Group E experiments.  17. Cloudflare lift, if wanted on section 5's grounds.

**Stop-rules.** Re-measure after items 8-10; if remaining spend is audit-dominated, jump to 15 and
leave 11-14 unbuilt. Every item ships its must-fire fixture and clean twin in the same commit. If I1
contradicts a ranking here, I1 wins.

## 7. How these could backfire

- **B-1** could block legitimately price-exempt items -> `no-board-price-ok.json` is the sanctioned
  escape and already exists; the fixture set includes an allowlisted clean twin.
- **B-2** could hold recipes at `mapped` if bid-wiring lags -> held recipes appear in `-Status` as a
  named follow-up list, not silence; that is the PARKED pattern already proven.
- **C1** mis-keyed rejects novel dishes (too coarse) or never matches (too fine) -> advisory until
  measured; the sourcer may override with a stated reason.
- **D1 snippets** could reject good recipes on thin text -> identity-dupes only, never nutrition.
- **D3** could suppress a genuinely novel dish in a crowded lane -> guidance to argue with, not a
  filter; overriding requires naming the axis.
- **C2 staleness** after a commodity split -> rows carry provenance; registrar rulings invalidate.
- **B-4** is the dangerous one: a wrongly-narrow scope ships unaudited bytes -> it may only skip
  re-verification of provably unchanged files, and the shared-data must-fire is the first fixture.
- **A3** could false-refuse when a repair legitimately concludes "nothing to change" -> the agent
  must SAY that, and the orchestrator treats "no change intended" differently from "changed X" with
  X untouched.

## 8. Explicitly out of scope

- **Weakening any gate to save tokens.** The audit's 31% bought two correct NO-GOs, caught a repair
  that lied, and exposed a live-site defect. Scoping it correctly (B-4) is on the table; cheapening
  it is not.
- **The wave boundary.** It amortizes `propagate-recipes` (which carries every dirty spec by design)
  and the whole-wave audit; per-recipe publishing multiplies both.
- **Publishing any way except wave-publish.ps1 after a GO.** Unchanged and non-negotiable.
