# PLAN: expiry-driven rescue worklists for the browser stores

Written 2026-07-31 (Fable), for an Opus implementation session. Self-contained: every constraint
you need is in this file, every anchor was verified against the tree on 2026-07-31. If an anchor
does not match when you get there, STOP and re-derive it: another session shares this tree and
files move.

## 0. Why this exists (measured, not assumed)

The four walled stores (Walmart, Sam's Club, Aldi, Fareway) are captured through the browser and
priced through a 14-day freshest-capture-wins union (`compare-deals.ps1`: `$WalmartMaxAgeDays = 14`,
`$SamsMaxAgeDays = 14`; the loader unions every capture inside the window and the freshest one
covering a commodity wins it OUTRIGHT). Two failure classes fall out of that design, both observed
live on 2026-07-31:

1. **The silent countdown.** 21 of 436 Walmart cells traced to `walmart-regular-2026-07-18.json`,
   which left the window the next day. They were almost all produce (cantaloupe, celery, cilantro,
   honeydew, kale, lemons, limes, mangoes, pineapple, watermelon...) because Walmart RENAMES produce
   ("Fresh Pineapple" -> "Fresh Pineapple, Each"), so newer captures missed them by name. Nothing
   emitted "capture exactly these 21 terms today"; the fullpull watch counts them but produces no
   worklist.
2. **The narrower re-capture.** Aldi's 2026-07-29 capture was its biggest ever (1,664 rows vs 438)
   and STILL cost 7 live staple cells (bottled-water, bread, canned-mushrooms, gelatin,
   hamburger-buns, hot-dog-buns, microwave-popcorn) because the new pass never searched those terms
   and the old file holding them aged out the same day (aldi-regular-2026-07-15 + 14d = 07-29).
   `audit-cell-drops` reported them after the fact; nothing turned them into a re-search list.

Also standing: ~20 Sam's cells serve from 15-18 day old captures (`sams-regular-2026-07-14.json` is
the orphan nothing writes; guard 9's warn documents it), which is a permanent staleness pocket the
worklist should surface every run.

The fix is ONE new tool that turns all three into per-store term lists a browser session can
execute directly, plus wiring, coverage, and fixtures.

## 1. House rules that bind every deliverable here

- **A check that examined nothing must WARN or exit 3, never print ok.** Exit 3 is the estate's
  could-not-evaluate code.
- **Advisory means advisory.** Nothing in this plan may hold a publish. Exit 1 = "found work",
  exit 0 = "nothing needed", exit 3 = blind.
- **Every new check ships a MUST-FIRE fixture (frozen, synthetic, never regenerated from the live
  board) plus a CLEAN TWIN, executing the REAL code path.** Fixtures run from a TEMP copy if the
  tool writes into its own input directory.
- **Mutant-test every check before commit.** On 2026-07-31 three brand-new checks were decorative
  on first writing (commit `0e3df480`'s message documents all three): a case-insensitive `-match
  'exit 2'` was satisfied by the COMMENT documenting the fix; `'\$hvRc'` stayed green after the
  variable was renamed because it is a substring of `$hvRcX`; `'\$capWarned'` survived in the
  initialiser after the assignment was mutated away. Assert ASSIGNMENTS and STATEMENTS
  (`-cmatch '(?m)^\s*exit 2\s*$'`, `'\$x\s*=\s*\$LASTEXITCODE'`), never bare names.
- **Delegated children: capture output, then log, then read `$LASTEXITCODE`. Never `2>&1` or
  `2>$null` on a native child** - this repo runs under `$ErrorActionPreference='Stop'`, where a
  redirected native stderr line becomes a terminating throw. Copy the caller shape from commit
  `0e3df480` (the Hy-Vee pull block or the everyday-mismatch block in `check-ad-cycles.ps1`).
- **PS 5.1 traps that have each bitten this repo:** `@()` around a `List[object]` THROWS (use
  `.ToArray()`); `'' | ConvertFrom-Json` returns `$null` silently; `ConvertFrom-Json` rows are
  heterogeneous (row 0's properties say nothing about row 500); `$Matches` is GLOBAL (use
  `[regex]::Match(...)` locals); a bare `return` at script scope exits 0; an undeclared `-Switch`
  under `-File` lands in `$args` without erroring; read files with `[IO.File]::ReadAllText`.
- **Commit only your own hunks.** Another session is active in this tree (it has in-flight edits to
  `import-walmart-batch.ps1`, `known-wrong.json`, `commodities.json`, `product-urls.json`,
  `stores.json` and others). `git add` file-by-file, never `-A`. If `stores.json` is dirty with
  someone else's change when you get there, coordinate or wait - do not sweep their edit into your
  commit.
- **No em dashes in anything user-facing.**
- **No silent caps:** if the tool bounds anything (lookback, sections, term mapping), say what was
  dropped in its own output.

## 2. Deliverable A - registry: mark the walled stores

`stores.json` (repo root of grocery\). Add `"walled": true` to exactly four entries: Walmart,
Sam's Club, Aldi, Fareway. Additive key only; touch nothing else in the file.

Why registry-driven: `audit-store-registry.ps1` scans code for store-name drift and the estate rule
is that store lists come from `stores.json`, never hardcoded. Note Aldi's `capture` field reads
"server (Flipp flyerkit JSON) + Instacart storefront for shelf prices" - you cannot select the
walled set by matching 'browser' in `capture`, which is exactly why the explicit flag is needed.

Verification: run `audit-store-registry.ps1` and `guards.ps1` after the edit; both must stay green.
If the registry audit rejects an unknown key, extend its schema tolerance in the same commit and
say so.

## 3. Deliverable B - the tool: `build-rescue-worklist.ps1` (new file)

Emits, per walled store, `out\rescue-terms-<urlkey>.txt` (urlkey from the registry: walmart, sams,
aldi, fareway): the search terms a browser session should run FIRST, so captures stop being
full-list fire drills.

### Parameters

```powershell
param(
  [string]$OutDir = "",            # default <root>\out; holds comparisons, captures, and the emitted lists
  [string]$StoresFile = "",        # default <root>\stores.json
  [string]$TermsFile = "",         # default <root>\commodity-search.json
  [string]$PullOrderDir = "",      # default $OutDir; holds pull-order-<urlkey>.txt
  [int]$WindowDays = 14,           # MUST match compare-deals' union window
  [int]$ExpireWithinDays = 5,      # matches the fullpull watch's warn horizon
  [int]$DropLookbackDays = 7,      # comparison-diff span for the DROPPED section
  [string]$AsOf = ""               # 'yyyy-MM-dd'; default today. REQUIRED for frozen fixtures -
)                                  # never call Get-Date for age math anywhere else in the file
```

Every path and the as-of date must be injectable or the fixtures cannot be frozen (this is the
lesson of audit-everyday-mismatch, which had NO param block and therefore never had a fixture).

### Algorithm

1. **Load the registry**; select stores where `walled` is true. Zero walled stores -> exit 3
   (config, not data). For each store, the capture-file index globs are:
   - always: `out\regular\<regular_prefix>-regular-*.json`
   - plus `deals_glob` (normalize `/` to `\`) ONLY when the store's `ad_cycle` starts with `none`.
     WHY: Sam's "deals" files (`out/sams/sams-deals-*.json`) ARE its everyday captures (its
     `ad_cycle` is "none (national/club everyday pricing)"), but Fareway's deals_glob is a genuine
     weekly SALE feed - indexing it would let a coincidental name+price match attribute an everyday
     cell to a younger sale file and hide a real expiry.
2. **Build the trace index** per store: newest-first over all files whose filename date parses
   (`[regex]::Match($f.BaseName,'\d{4}-\d{2}-\d{2}')`), INCLUDING files older than the window
   (needed for the STALE section - Sam's serves from 15-18d files today). Key =
   `item.ToLower().Trim() + '|' + ad_price string`; first (newest) file wins the key.
3. **Trace today's board**: newest `comparison-*.json` in `$OutDir` (none -> exit 3, blind). For
   every EVERYDAY cell (`type -eq 'everyday'`) of a walled store, look up its key:
   - traced, `ageDays > $WindowDays` -> **STALE-UNREFRESHABLE**
   - traced, `($WindowDays - ageDays) -le $ExpireWithinDays` -> **EXPIRING** (record days-left)
   - not traced at all -> **UNTRACEABLE** (unknown provenance = capture it; conservative)
   - otherwise healthy.
4. **DROPPED section**: take the newest comparison whose date is `>= $DropLookbackDays` older than
   the current one (fall back to the oldest retained if none is old enough, and SAY SO in the
   output header). Every (commodity, walled store) pair with an everyday cell there and NO cell of
   any type today is DROPPED. Note the deliberate divergence from `audit-cell-drops.ps1`: that
   audit EXCLUDES Sam's because slices aging out is policy; this tool INCLUDES Sam's because the
   shopper still lost the price and a capture fixes it. Document that divergence in a comment in
   BOTH files.
5. **Map commodity -> term** via `$TermsFile`: the `terms` object is `{commodityId: "search term"}`
   (526 entries). A rescue commodity with no term entry goes in a NO-TERM footer with its id -
   never silently dropped.
6. **Rank**: within each section, by the line number of the term in
   `pull-order-<urlkey>.txt` (format: `commodityId<TAB>term`, one per line, best first). Missing
   pull-order file -> keep section order, note "unranked" in the header. Section order in the
   file: DROPPED, UNTRACEABLE, EXPIRING (ascending days-left), STALE-UNREFRESHABLE.
7. **Emit** `out\rescue-terms-<urlkey>.txt` with a header comment carrying: generation date, AsOf,
   thresholds, per-section counts, and THIS WARNING verbatim, because the engine hands a commodity
   to the freshest capture outright and a shallow rescue makes things worse, not better:
   `# DEEP CAPTURE REQUIRED: for every term below, capture ALL qualifying products, not the first`
   `# match - a narrow re-capture WINS the commodity with thinner data (grapefruit went fresh->canned`
   `# this way). If a term cannot be captured deep, skip it and leave the old file to serve.`
   Body lines: `term<TAB>commodityId<TAB>section<TAB>detail` (detail = days-left / drop date / file
   age). Write the file even when empty (header says "nothing at risk") so a stale previous list
   can never be mistaken for today's.
8. **Coverage row** (`coverage-lib.ps1`, `Write-CoverageRecord`): check name
   `build-rescue-worklist`, `-OutDir $OutDir`, Eligible = everyday walled cells examined,
   Examined = cells successfully traced, `-Blind` when Examined 0 with Eligible > 0. Wrap in
   `try {} catch {}` like every other emitter.
9. **Exit codes**: 3 = could not evaluate (no comparison / no walled stores / traced nothing while
   cells existed); 1 = at least one section non-empty in at least one store (advisory: work
   exists); 0 = ran, everything healthy. Print a one-line per-store summary either way, e.g.
   `rescue [Walmart]: DROPPED 0  UNTRACEABLE 0  EXPIRING 21  STALE 0 -> out\rescue-terms-walmart.txt`.

### What NOT to do

- Do NOT refactor `audit-walmart-fullpull.ps1` to share a tracer lib. It has its own fixtures and a
  different job (watching comprehensive-capture age). Duplicated tracing is a documented,
  acceptable drift risk here; a broken watcher is not. Put a cross-reference comment in each.
- Do NOT gate anything. This tool's output is a to-do list for a browser session, nothing more.
- Do NOT use `Get-Date` for anything except defaulting `$AsOf`.

## 4. Deliverable C - wiring into `check-ad-cycles.ps1` (cycle phase, advisory)

Insertion point: AFTER the everyday-mismatch block (search anchor: `THE BOARD vs ITS OWN LINKS`)
and BEFORE the coverage ratchet block (anchor: `COVERAGE RATCHET FOR THE CYCLE PHASE`), so the
comparison is final and the tool's coverage row is on the ledger when the ratchet reads it.

Copy the everyday-mismatch caller shape EXACTLY (capture into a variable; `foreach ... Log`; read
`$LASTEXITCODE` into `$rwRc`; no `2>&1`/`2>$null`; the whole thing in its own `try/catch`):
- `$rwRc -eq 1` -> `$summary += 'REVIEW    rescue-worklist: capture work exists for the walled
  stores - see out\rescue-terms-*.txt (DROPPED/EXPIRING cells will leave the board if not captured)'`
  and parse the per-store counts for the log with `[regex]::Match`, never `-match`+`$Matches`.
- `$rwRc -eq 3` -> REVIEW line saying the walled-store freshness check proved nothing this cycle.
- other non-zero or zero output lines -> the DID-NOT-RUN review shape.

Cry-wolf check (required before commit): run the wired cycle path once with `-NoAlert`-equivalent
flags if available, or run the tool standalone against the live out\ and confirm the summary fires
only because real work exists (on 2026-07-31 it will: Aldi has 7 genuine drops). A healthy day
(all sections empty) must produce exit 0 and NO summary line - verify that with the clean twin.

Census note: being invoked from `check-ad-cycles.ps1` makes the new script reachable, so
`audit-script-census.ps1` needs no `$KNOWN` entry. Run it to confirm.

## 5. Deliverable D - `coverage-baseline.json` entry

Add under `checks` (phase `cycle`, `max_age_days: 3` because it runs on the ad cycle):

```json
"build-rescue-worklist": {
  "examined": <measure it>, "tolerance": 0.1, "max_age_days": 3, "phase": "cycle",
  "why": "everyday walled-store board cells traced to a dated capture file. Board-derived like guards/4-factor, so the measured 0.10 band applies. Eligible is everyday cells of the four walled stores only; examined falls to 0 (BLIND) if the capture files vanish from out\\, which is the fresh-clone / cloud-runner state."
}
```

Measure `examined` from the real first run (expect ~1,450-1,550; it was 436+347+335+407 = 1,525
walled cells on 2026-07-31, everyday subset slightly lower). Never guess it; the baseline readme
demands measured values.

## 6. Deliverable E - fixtures + test-auditors + mutant matrix

New fixture dirs under `regression-inputs\guard-fixtures\` (all synthetic - invented store
"Fixture Mart", invented products, dates in January 2000; never copy live board data):

- **rescue-mustfire\\**: `stores.json` (one walled store, `regular_prefix: fixturemart`,
  `ad_cycle: "none (fixture)"`, plus `commodity-search`-shaped terms file and a 3-line pull-order),
  `comparison-2000-01-10.json` (cells: fx-milk everyday traced to an old capture; fx-toast everyday
  with NO capture row anywhere -> UNTRACEABLE), `comparison-2000-01-03.json` (has fx-eggs cell that
  01-10 lacks -> DROPPED), `regular\fixturemart-regular-2000-01-01.json` (fx-milk row, name+price
  matching the cell -> age 9d at AsOf 2000-01-10, days-left 5 -> EXPIRING). Invoke with
  `-AsOf 2000-01-10 -OutDir <tempcopy>` and assert: rc 1; fx-eggs in DROPPED; fx-toast in
  UNTRACEABLE; fx-milk in EXPIRING with days-left 5; the emitted file exists and carries the
  DEEP CAPTURE header.
- **rescue-clean\\**: same shape, capture dated 2000-01-09 (1d old), both comparisons carry the
  same cells. Assert rc 0, all sections 0, file emitted with "nothing at risk".
- **rescue-blind\\**: stores+terms present, NO comparison file. Assert rc 3 and the
  could-not-evaluate wording.

Run every fixture from a TEMP copy (the tool writes rescue-terms files and a coverage row into
`-OutDir`; a fixture that mutates itself is not frozen). Follow the `EmFixture` helper pattern in
`test-auditors.ps1` (anchor: `function EmFixture`).

test-auditors checks to add (match the file's Ok/Bad + RunPS idiom; anchor to insert after: the
`(v2) the Hy-Vee pull's own numbers` block):
1. Behavioural: the three fixtures above (must-fire, clean twin, blind).
2. Source: `check-ad-cycles.ps1` still invokes `build-rescue-worklist.ps1` (orphan-again check -
   being uncalled is this class's founding bug; see audit-everyday-mismatch, which spent its whole
   life as an orphan).
3. Source: the caller reads the exit code - assert the ASSIGNMENT
   (`\$rwRc\s*=\s*\$LASTEXITCODE`) AND a branch (`\$rwRc\s*-eq\s*1`), not the bare name.
4. Source: the caller does not use `2>&1` or `2>$null` on this child.
5. Source: `stores.json` still has 4 `"walled": true` entries (count them from the parsed JSON,
   not a regex over the text).

Mutant matrix - run each, assert test-auditors goes red, restore byte-identical (hash-check), and
run them ONE PER PowerShell call so a tool timeout can never strand a mutated file (that exact
accident happened on 2026-07-31 and left `-Phase cycle` rewritten to `-Phase all` in production;
my own orphan-check caught it, but only because it existed):
1. Neutralize the EXPIRING comparison (threshold to -1 or invert the test) -> must-fire loses fx-milk.
2. Break the DROPPED diff (compare the new comparison to itself) -> must-fire loses fx-eggs.
3. Make the tool `exit 0` unconditionally -> blind fixture check fails.
4. Remove the invocation line from check-ad-cycles -> orphan check fires.
5. Rename `$rwRc` on the assignment only -> assignment check fires.
6. Drop one `"walled": true` from stores.json -> registry-count check fires.

## 7. Deliverable F - one-line cleanup while you are in guards.ps1's neighborhood

`guards.ps1` line ~176 still invokes cell-drops as
`& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-cell-drops.ps1') 2>$null`.
The `2>$null` on a native child under EAP=Stop is the exact idiom removed from the delegated-audit
loop earlier (it turns a child's first stderr line into a terminating throw; here it is inside its
own try/catch, so the blast radius is "cell-drops reports as could-not-run instead of its real
output" - wrong signal, not a dead guard). Remove the redirect, run guards to confirm green, and
extend the existing delegate-stderr negative test if one does not already cover this call site.
Small, but it is the same disease this whole plan treats.

## 8. Explicit non-goals (do not scope-creep into these)

- Capture-time union-coverage diffs inside the builders: SUBSUMED by this tool run daily (the Aldi
  drop case is caught days earlier by the EXPIRING section).
- Aldi/Fareway out-of-band verification cells: browser work, not code.
- The ~200 captured-but-unused verified Sam's prices and the Sam's 07-14 orphan data itself: Brad's
  call, not code. The STALE section merely keeps them visible.
- `discover-hyvee.ps1` / pull-depth work: separate program, separate decision.
- Headless stores (Hy-Vee, Family Fare, Baker's): their drops have different remediation (term
  cursor, API vocabulary), not a browser worklist. Walled four only.

## 9. Acceptance checklist

- [ ] Parse-check every touched file (`[System.Management.Automation.Language.Parser]::ParseFile`).
- [ ] Live run: `build-rescue-worklist.ps1` exits 1 today and the Aldi list contains the dropped
      staples (bottled-water, bread, canned-mushrooms, gelatin, hamburger-buns, hot-dog-buns,
      microwave-popcorn - whichever are still dropped when you run); Sam's list has a non-empty
      STALE section; the summary lines print per-store counts.
- [ ] All three fixtures behave (1 / 0 / 3) from a TEMP copy.
- [ ] Full mutant matrix: 6 mutants, 6 reds, all files restored hash-identical.
- [ ] `test-auditors.ps1` green (it was 258 checks before this work; it must end higher).
- [ ] `guards.ps1` exit 0; `audit-script-census.ps1` exit 0; `audit-store-registry.ps1` green;
      `regression-test.ps1` 37/37; `audit-coverage-ledger.ps1 -Phase cycle` shows the new row ok.
- [ ] Commit YOUR files only (expect: the new script, check-ad-cycles.ps1, stores.json IF clean of
      foreign edits, coverage-baseline.json, test-auditors.ps1, guards.ps1, fixture dirs). Message
      follows the house style: what broke, why it was invisible, what proves it can't regress.
      End with the Co-Authored-By line. Push and confirm origin advanced.

## 10. Templates worth reading first (in this repo's history)

- Commit `0e3df480` - the caller shape, fixture style, TEMP-copy discipline, and the three
  decorative-check post-mortems this plan's mutant rules come from.
- Commit `3014ab5c` - the exit-3 blind convention end to end (ff-carry).
- `audit-everyday-mismatch.ps1` as it exists now - param-injectable inputs, blind gate, advisory
  exit codes: the closest living relative of the new tool.
