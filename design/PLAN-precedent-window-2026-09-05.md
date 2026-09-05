# PLAN: the decider's memory as a precedent WINDOW, not a history dump

queue_id: precedent-window-2026-09-05
shipped_commit: a5a589f8 (2026-09-05) - P1, P2, P3 and P4 are DONE: verify and report, do not
rebuild. P5 was the fallback if P1 were refused and is deliberately NOT built. P6 is parked.
MEASURED THROUGH THE SHIPPED ROAD: 18 of 23 cited precedents inside the k=10 window (bar >= 16);
prior_rulings 16,158 -> 4,332 bytes per candidate, max/min 12564x -> 1.3x (bars <= 5,500, <= 1.5x);
the sidecar call 4.2 s for a batch of 10 (bar <= 15 s).
CORRECTION to section 5: harvest_embed.py and considered-dishes.ps1 do NOT carry --names-out;
their case-name diffs were hand-rolled.
author: Fable 5.1, 2026-09-05, PLAN ONLY. Written for a fresh session to build from. Every number
below was measured today against the files; every claim about a file names the line it was read at.
ruled by: Brad, 2026-09-05 - "we don't want to cut it" (a count cap on `prior_rulings` is refused),
then "what is the SMARTEST thing to do that scales as we add more recipes? We need accuracy and
scalability", then "review the above and see if that is truly the smartest approach. If so, develop a
PLAN for a new session to build."
review this hangs off: section 0 below, which is the review. The proposal reviewed is the one made
in this conversation by Opus 5 on 2026-09-05 (region summary + similarity-ranked precedents + direct
`dupe_of` lookup + an honest window statement).

## 0. The review: is that actually the smartest approach?

**Yes, in direction - and it is not new to this estate, which is the strongest thing in its
favour.** The map lane already does exactly this for ingredient terms: `fill_prior_rulings`
(`hunt-daemon.py:3609`) asks `resolution_embed.py --query` for the k nearest PAST rulings by bge-m3
cosine, on the sidecar interpreter, with three states (`ok` / `empty` / `blind`) that are never
faked and never blocking. The decide lane's `prior_rulings` is the one memory in the pipeline still
delivered by coarse key match with no ranking and no bound. The smartest thing is not a new
mechanism; it is bringing the decide lane onto the road the map lane already proved.

**Four corrections to the proposal as made, each measured today:**

1. **It overstated what `prior_rulings` does for the decider.** Of the 215 `rejected-dupe` rulings in
   `db\considered-dishes.json`, the reason names a LIVE recipe in 160 (153 live only, 7 both) and a
   prior LEDGER ruling in 23 (16 ledger only, 7 both); 39 name neither by slug. So the live-catalog
   `neighbours` block carries ~74% of the cited precedent and `prior_rulings` ~11% - while costing
   89% of the dossier bytes in a saturated region. The list is not worthless (23 real citations, and
   consistency across runs is what it exists for), but its size is out of all proportion to its use.

2. **"A region summary line" half-exists.** `saturation_pressure` (`harvest.py:1760`, from
   `db\saturation.json`, 36 protein|family regions with counts) is already the crowding signal, as an
   integer. What is missing is the RULING mix per region (accepted / rejected-dupe / not-fit), and it
   must be a sibling field: `dossier_rank` (`harvest.py:2790`) and the fixtures at `harvest.py:3572-
   3578` read `saturation_pressure` as an int.

3. **The case is NOT token spend.** This estate measured that wall clock is OUTPUT tokens
   (EVAL-hunter-wall-clock section 2b); `prior_rulings` is input, cached between calls. The case is
   the estate's own stated invariant, which this field breaks: `dossier_neighbours`'s docstring
   (`harvest.py:2811`) - *"The dossier's cost per candidate stays CONSTANT in catalog size either
   way, which is the property the cap exists for."* Ingredients are capped at 22
   (`DOSSIER_INGREDIENT_CAP`, `harvest.py:124`, "keeps a dossier at the 2-3 KB section S2 budgets");
   neighbours at `DOSSIER_NEIGHBOUR_CAP` per channel per side; `same_family_other_protein` at 5
   (`considered-dishes.ps1:260`). `prior_rulings` alone grows with the ledger. Measured on the live
   pool today: 1,205 available, mean 15.3 entries, 239 candidates (20%) carry more than 40, and
   the five heaviest carry exactly 60 - which is not a cap, it is the entire `chicken|bake|plain`
   region (60 rows). The ledger adds ~45 rows per active hunting day (406 rows over 9 dates).

4. **The accuracy claim was a hypothesis. It is now a measurement, and it holds.** For the 23
   citations of a prior ledger ruling, ranking every other ledger row by bge-m3 cosine to the
   candidate (`signature_text`, same model and cache as the catalog index, read-only, 0 tokens):

   | road | cited precedent present at all | in top 5 | in top 10 | in top 20 |
   |---|---|---|---|---|
   | today's key match (region list, unranked) | 16 of 23 | 14 | 14 | 15 |
   | similarity over the WHOLE ledger | **23 of 23** | 16 | **18** | 20 |

   Today's road cannot even SHOW 7 of the 23 precedents the decider cited - they sit in a different
   coarse region (`sausage-spinach-crustless-quiche` cites `sausage-cottage-cheese-egg-bake`, region
   size 0; `flat-ground-beef-enchiladas` cites `easy-beef-enchiladas`, global rank 2). A similarity
   window of 10 delivers more of the estate's own cited precedent than the unbounded list does, and
   its size does not move with the ledger. The two misses at top-20 are loose citations (`thai-basil-
   ground-beef-pad-kra-pao` -> `thai-coconut-curry-pork-shoulder`, rank 128; `sheet-pan-lemon-
   chicken` -> `easy-chicken-and-potatoes`, rank 104): the decider naming a region, not a twin.

   n=23 is small and the citation extraction is a regex over prose. P3 below is what makes the
   next measurement exact.

**Verdict.** Build it - as the map lane's road, with the corrections above, and with the window
stated in the dossier so the decider always knows it is seeing a window. Brad's ruling stands
untouched: nothing here is a count cap on the list the decider gets today; it is a different list,
ranked by relevance to the candidate, that carries MORE of what the decider has cited while staying
constant in size.

## 0a. Read these first, in this order

1. Section 0 above, then `hunt-daemon.py:3609-3700` (`fill_prior_rulings` + `render_prior_rulings`)
   and `resolution_embed.py:178-300` (`rank`, `cmd_query`). That is the design, already shipped for
   terms. Copy its shape; do not redesign it.
2. `harvest.py:1706-1765` (`score_pool`, where `prior_rulings` is attached nightly from
   `batch_prior_rulings`), `harvest.py:2804-2850` (`dossier_neighbours`, `build_dossier`), and
   `considered-dishes.ps1:97-118, 250-263` (`Get-Rulings`, the batch road).
3. `hunt-daemon.py:1198-1260` (`decide_lane`, the dispatch at 1252) and `:1300-1336`
   (`decide_prompt`, which already mutates dossiers at dispatch - the seam).
4. `harvest_embed.py:114-121` (`signature_text`) and `:211-260` (`Embedder`, `HARVEST_CACHE`). The
   ledger's 406 rows all carry `name` + `protein` - exactly `signature_text`'s shape - so their
   embeddings share the catalog's cache and are nearly free.
5. `.claude\agents\recipe-dedup-selector.md:33-36` - the decider's contract for `prior_rulings`
   ("ADVISORY") and `saturation_pressure`.
6. `EVAL-dedup-shortlist-2026-09-04.md` section 9 and `PLAN-after-review-2026-09-04.md` P6 - why
   the input drop was population, not code, and why this plan exists.

## 1. Where things stand (measured 2026-09-05)

    ledger            406 rows; 215 rejected-dupe, 93 accepted, 88 rejected-not-fit; ~45 rows/active day
    largest region    chicken|bake|plain 60 rows; chicken|skillet|plain 48
    pool              1,205 available; prior_rulings mean 15.3, >40 on 239 (20%), max 60
    dossier bytes     five-b's 19 candidates: 18,227/cand, of which prior_rulings 16,160 (89%)
    per entry         503 bytes, mostly `reason` prose; arrives in LEDGER order (oldest first)
    cited precedent   23 of 215 dupe rulings cite a prior ledger ruling; similarity top-10 holds 18,
                      today's key-match list holds 16 at any depth

## 2. The work, ranked by what it buys

### P1 - The precedent window: k nearest past rulings, at dispatch, on the map lane's road

**What it buys.** The constant-cost invariant back for the last field that breaks it, and MORE of
the cited precedent than today (23/23 reachable vs 16/23; 18 vs 14 in the top ten). Fresh at every
batch instead of once nightly - today a run's batch 2 cannot see batch 1's rulings through
`prior_rulings` at all, because the field is written at the nightly rescore.

**Build.**
- A `--precedents` road in `harvest_embed.py` (NOT `resolution_embed.py`: its corpus is the
  ingredient EVENT log keyed by term, a different text shape and a different cache). Input JSON
  `{"queries": [{"slug", "name", "protein"}]}`; corpus = every `considered-dishes.json` row embedded
  through `signature_text(name, protein)` on `HARVEST_CACHE`; output per query: the top `k` rows
  (`slug, name, key, verdict, reason, dupe_of, run, at, score`), plus `in_region` (rows sharing the
  candidate's coarse `protein|method` key - what today's road returns), `in_ledger`, and a top-level
  `state` of `ok` / `empty` / `blind` with `why`. **Leave-one-out by slug**: a candidate re-ruled
  after a deferral must never see its own earlier ruling as precedent (`resolution_embed.rank` has
  this rule by key; copy it).
- In the daemon, at the dispatch seam: `decide_lane` calls `self.py(HARVEST_EMBED_PY, ["--precedents",
  qin, "--out", qout], exe=SIDECAR_PY)` for the batch BEFORE `decide_prompt` (the call at
  `hunt-daemon.py:1252`; `self.py` at `:659`; `fill_prior_rulings` at `:3609` is the template,
  including its `PRIOR_TIMEOUT`). Verify the seam is awaitable where you put it - do not assume.
- Each dossier's `prior_rulings` becomes the window, and a sibling `prior_rulings_window` states
  it: `{"shown": 10, "in_region": 77, "in_ledger": 406, "ranked_by": "bge-m3 cosine to this
  candidate", "state": "ok"}`. On `blind`, `prior_rulings` is left as the nightly key-match list
  the pool already carries and `state` says `blind` with the reason - a window that could not be
  built is never an empty list pretending it looked (the rule `fill_prior_rulings` was built on).
- `k` is a named constant beside `DOSSIER_INGREDIENT_CAP` with the measurement in its comment. **The
  number is Brad's ruling, not the builder's**; the bars below say what any `k` must clear. 10 is
  what section 0 measured.
- `score_pool` keeps writing the nightly key-match list as today. It is the blind-state fallback.
  Dropping it from the pool is P6 (parked), not this item.

**Bars, before the build.**
- Re-run section 0's measurement through the SHIPPED road (the same 23 citations, the shipped `k`,
  the shipped ranking): the window must contain **at least 16 of 23** - it may not deliver less
  cited precedent than today's unbounded list - and the build reports the actual count. 18 is what
  the prototype scored; below 16 the item is refused, not tuned.
- Dossier bytes for five-b's 19 slugs, rebuilt through `build_dossier` with the window: the
  `prior_rulings` block **<= 5,500 bytes per candidate** at k=10, and CONSTANT - max/min across the
  19 <= 1.5x. That is the invariant, and it is the number that must not move when the ledger doubles.
- The sidecar call for a batch of 10, cache-hot: **<= 15 s** (measure; `PRIOR_TIMEOUT` is 120).
- With the sidecar interpreter absent (rename it in a scratch copy of the run dir's env, never on
  disk), the dossier carries the nightly list and `state: blind` with a reason, and the run proceeds.

### P2 - The region's ruling mix, as a sibling of `saturation_pressure`

**What it buys.** The crowding signal the proposal wanted, in one line instead of a list the decider
counts for itself: `region_rulings: {"key": "chicken|bake|plain", "in_ledger": 60, "accepted": 11,
"rejected_dupe": 34, "rejected_not_fit": 15}`. Computed in the SAME `--precedents` call (the
ledger is already loaded); written beside, never into, `saturation_pressure`, which stays an int
(`dossier_rank`, `harvest.py:2790`; fixtures `harvest.py:3572-3578`).

**Bars.** The four counts sum to `in_ledger`; `saturation_pressure` is still an int on every
dossier the daemon suite builds; the dossier fixture at `harvest.py:3519` still lists the same
required keys plus the new one.

### P3 - Structured citations, so the next measurement is exact and not a regex

**What it buys.** Section 0's 23 came from a regex over `reason` prose, which is why n is 23 and
why 39 dupe rulings cite "neither by slug". The decider knows exactly which rows it relied on; make
it say so. Then P1's bar can be re-measured on every run automatically, and P6's number for `k`
comes from the estate's own citations rather than from a one-day sample.

**Build.** An optional `precedents: [ledger slugs]` on the DECIDE decision record (`hunt_lib.py:72-
84`), carried by `decide_apply` into the `considered-dishes.ps1 -Record` call as `-Precedents`
(a LIST - the B8 class; `dupe_of` at `decide_apply.py:164` is the template), stored on the ledger
row, and one sentence in the agent contract (`recipe-dedup-selector.md:33`): name the `prior_rulings`
slugs you relied on. A missing field is empty, never an error.

**Bars.** After the next three decide runs: of the rulings that name a precedent, **>= 90% of named
precedents were inside the window shown**. Below that, either `k` or the ranking is wrong, and the
pairs - not the count - go to Brad. Zero named precedents across three runs is ALSO a finding: the
contract sentence did not land.

### P4 - The contract says it is a window

**Build.** `recipe-dedup-selector.md:33` currently says `prior_rulings` is "what this estate has
already ruled about this dish identity". Change it to say what it now is: the nearest past rulings
by similarity, `shown` of `in_region`, and that `in_region > shown` means the region is crowded
beyond what is displayed - defer with a reason rather than assume the window is the whole ledger.
`decide_prompt`'s preamble (`hunt-daemon.py:1325-1331`) explains `neighbours` sides and
`catalog_checked`; add the one sentence for `prior_rulings_window` there too. Ships WITH P1; a
window the decider does not know is a window is a silent cut.

### P5 - Fallback only: newest-first ordering, if P1 is refused

If Brad refuses P1 as a whole, the one defect that stands on its own is that today's list arrives
oldest-first (five-b's example candidate: first entry 2026-08-23, ledger order). Sort
`batch_prior_rulings`' output by `at` descending in `score_pool`. Drops nothing, costs nothing,
and makes any later window safe. **Not built alongside P1** - P1 replaces the ordering with a
ranking, and two orderings on one field is a defect waiting for a reader.

### P6 - Parked on rulings, listed so they are not lost

- **`k`.** The window size is Brad's. Section 0 measured 10; P3 is what will re-measure it.
- **The two loose citations** (`thai-basil-ground-beef-pad-kra-pao` -> `thai-coconut-curry-pork-
  shoulder`; `sheet-pan-lemon-chicken` -> `easy-chicken-and-potatoes`): read them and decide whether
  a window that misses them is missing anything.
- **Dropping the nightly key-match list from the pool** once P1 has run clean for a week: it is
  ~20 KB on a fifth of the rows and the blind-state fallback. A ruling, because it removes the
  fallback.
- **Whether `rejected-not-fit` rows belong in the precedent corpus.** Brad ruled against cutting by
  verdict; they stay in. Recorded because 88 of 406 rows answer a question the dossier does not ask.
- From the previous plan, unchanged: P4 there (the decider rules the 18 flagged published pairs -
  Brad launches), the within-pairs decider experiment, and the seven P7 rulings.

## 3. What this plan deliberately does NOT do

- **It does not cap `prior_rulings` by count on today's list.** Brad refused that on 2026-09-05 and
  the refusal is right: a count cap on an unranked list keeps the oldest and drops this week's.
  P1 is a different list, ranked, with the window stated.
- **It does not change the decider's rule, the rubric sentence, or any verdict.** The window is
  evidence; the agent contract still says ADVISORY and still says the decider may accept over a
  prior rejection with a reason.
- **It does not filter rulings by verdict** (see P6).
- **It does not start llama-server, and nothing here runs on the card.** bge-m3 on the CPU, on the
  sidecar interpreter, from the DAEMON - the crawl is untouched and its three card fixtures stay
  green by construction.
- **It does not write the pool from the daemon.** The window lives on the dispatched dossier;
  `harvest.py` stays the pool's sole writer.
- **It does not hard-code a band, and it does not touch the ingredient-term precedent road**
  (`fill_prior_rulings`), which is the template, not the target.
- **It does not delete anything from the ledger**, and does not backfill `precedents` onto old rows.

## 4. Fixtures and neuters, per item

Each item ships with MUST-FIRE / CLEAN-TWIN pairs in the suite that owns the code, and at least one
neuter run ONE AT A TIME with the count MEASURED and the file restored by md5. Write the measured
counts into the commit message; never predict them. Verify every "the suite already pins X" claim
by opening the suite - this plan names the lines it read and no fixture it did not.

- P1  `harvest_embed.py --selftest`: the window is ranked by score descending and carries
      `in_region` / `in_ledger` counts (must fire); leave-one-out - a query slug's own ledger row
      never appears in its window (must fire); an empty ledger is `empty`, not `blind` (twin).
      `hunt-daemon.py --selftest`: with the sidecar answering, the dispatched dossier carries the
      window and `state: ok` (must fire); with the sidecar failing, it carries the nightly list and
      `state: blind` with a reason, and the batch still dispatches (must fire); the run log says
      which (twin). Neuters: ranking replaced by ledger order -> the 23-citation bar drops and the
      ranked-descending case reds; the blind branch removed -> the blind case reds.
- P2  counts sum to `in_ledger` (must fire); `saturation_pressure` is still an int on the same
      dossier (twin). Neuter: the sum check reduced to `>= 0`.
- P3  a decision carrying `precedents` reaches the ledger row (must fire, through the real
      `considered-dishes.ps1 -Record` - copy the `dupe_of` drill in `decide_apply.py --selftest`);
      a decision without it stores an empty list, never errors (twin). Neuter: `-Precedents` dropped
      from the args list.
- P4  the agent contract and the `decide_prompt` preamble both name `prior_rulings_window`
      (must fire, needle built by concatenation - see memory `selftest-greps-its-own-source`).

## 5. Gates

`harvest.py --selftest`, `harvest_embed.py --selftest` (sidecar interpreter), `decide_apply.py
--selftest`, `hunt-daemon.py --selftest`, `hunt-run.ps1 -SelfTest`, `harvest-crawl.ps1 -SelfTest`,
`considered-dishes.ps1 -SelfTest` (P3). All five Python/PS suites now carry `--names-out` /
`--names-diff` (or the PS equivalent) since 5137fa56: pin the reference from HEAD's bytes BEFORE the
first edit, diff by NAME, exit code first, tally second, nothing removed unless the commit says which
and why. Commit with `git commit -F`, explicit `git add` paths, never `-A`. Then the review road:
`design\PROMPT-fable-review-after-dedup-2026-09-04.md` is the shape of the review this should get.

## 6. Order

P1 and P4 together (a window the decider is not told about is a cut). P2 in the same sidecar call.
P3 immediately after, so the very next run starts producing exact citations. P5 only if P1 is
refused. P6 on rulings. Then the previous plan's P4 (Brad launches) with the window in place, so the
18 flagged pairs are ruled with the same evidence shape every future candidate will get.
