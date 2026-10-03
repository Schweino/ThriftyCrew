# MEASURE: which `ConvertTo-Json | Set-Content` writes land on a tracked path, and what converting them does to the bytes

Measured 2026-10-03 by the session that converted them. The census ran over origin/main at e32cfbced with the two
landed LF commits (be488f9ff, c6727af63) applied; the byte runs ran in a scratch CLONE of that tree carrying the
conversion, seeded from the main checkout (`ops/seed-worktree.ps1 -Source C:\Codex\ThriftyCrew`, 35 seeds, 28 boards).

## Knowledge consulted

- `.claude/rules/ops-and-gates.md` og-39: "a tracked file written under PS 5.1 is written LF (Write-TcLfFile,
  lib/lf-write.ps1) ... Verify by bytes: git status --short empty and a CR count of 0." The verdict below is read
  in exactly those two terms.
- og-25 (Write-TcAtomicFile for a file something else reads), og-11 (a ratchet, never a gate red on day one), og-33
  (a sandbox that runs a real script copies the whole lib\), og-45 (declared gate inputs, -VerifyDeclared).
- `.claude/rules/measurement.md` ms-04 (one row per case per arm, totals derived from the rows), ms-07 (name the
  harness and its blob).
- memory `crlf-flip-is-invisible-in-git-diff`. It bit this measurement: see "What went wrong the first time".
- `ops/count-tracked-writers.ps1` (blob 0264f167066365f90abf5c0c176abe37a62be944), found by knowledge-search and
  used as the independent cross-check of the census.

## Verdict first

- **Census.** The brief's `git grep -E "ConvertTo-Json[^#]*\|\s*(Set-Content|Out-File)" -- '*.ps1'` matched 467 lines
  in 232 files (reproduced exactly). Parsed instead: 462 pipelines; 136 inside self-test bodies (lib/selftest-lib.ps1's
  Get-SelfTestSpans); 98 in archive\ or grocery\out\ one-off scripts; **228 live production write sites, 130 of them
  on a tracked path.** The other 98: 36 gitignored, 14 not tracked (new files that were never committed), 10 run
  artifacts (meal-prep\runs specs and prose: 0 ever tracked), 9 temp, 3 caller-chosen paths, 26 grocery\test-guards
  writes whose bytes RestoreAll writes back. One row per site is in section 3.
- **Cross-check.** Against `ops/count-tracked-writers.ps1`, site by site over all 228: it found two of my verdicts
  wrong (export-identity-eval:164 writes `sidecar/data/mine-labelled.json`, force-tracked inside an ignored directory;
  recover-sams-quarantine:101 writes `<name>rejects.json`, a family with 0 tracked files). Both corrected before any
  conversion. Every other disagreement was explained: its resolver cannot follow `$f.FullName` or an absolute literal,
  and its suffix match claims archive and fixture copies of a name.
- **Blob state of the 130 targets at HEAD.** 122 BOM + LF; 6 sites over 5 files no BOM + LF (commodities.json twice,
  categories, commodity-search, recipes-db, measure-vs-grams-carry); 2 no BOM and no trailer
  (ghost-drift-recipes, store-walmart2-urls). CR 0 in all 130. Dated families were judged by their newest committed
  instance and checked for consistency over the last six: all BOM + LF except url-inputs\store-*.json and the bakers
  and fareway deals files, which are MIXED, so their two writers use `-KeepShape`.
- **Bytes, the acceptance bar, written before the byte runs** (og-39's own words): after a converted tool runs, no
  tracked file it wrote carries a CR, and where the content did not change `git status --short` is empty.
  **Met over everything exercised.** 37 runs paired old (HEAD's writer) against new, 19 of which exercised a tracked
  write. Old arm: 21 tracked files written, 20 with CR (1 to 151,814), 3 of them ` M` with a zero-line diff. New arm:
  18 tracked files written, **0 with CR**, and those 3 left `git status --short` empty. Content diff identical in
  21 of 21 files compared. The 21st old-arm file with no CR is audit-tile-integrity -Tighten, already an LF writer.
- **Not exercised, said plainly.** 31 of the 92 converted scripts were run; 19 of those exercised a tracked write.
  The other 12 wrote no tracked file in either arm under the seeded inputs (their write sits behind a condition the
  data did not meet; 18 of the 37 runs). 61 converted scripts were not run at all:
  the pullers and anything that reaches a network, the -Apply mutators, and the three that hard-code
  `C:\Codex\ThriftyCrew` (build-freezer-data, normalize-recipe-ids, purge-bad-lows), which would have written the main
  checkout. Those rest on the library fixtures (lf-write 9 of 9, atomic-write 34 of 34) and on every converted
  file parsing, loading its library before use (92 of 92, read off the AST) and keeping its HEAD BOM and line endings.

## 1. Method

The census harness is a one-off, kept as a description (ms-07): parse every tracked .ps1 that names ConvertTo-Json
with the PowerShell parser; take each PipelineAst whose last command is Set-Content/sc/Out-File and whose head calls
ConvertTo-Json; mark it a fixture when Get-SelfTestSpans says so; resolve its target expression by hand (literals,
same-file assignments, param defaults, the Get-ChildItem a `$f.FullName` loops over); then ask `git ls-files` for the
concrete path, and for a dated family whether a recent instance is committed (`git log -1` per family: all seven
`*-regular` files, aldi/walmart/sams rejects, sams-deals and taxonomy-disagreements were committed 2026-10-02) or
whether a new one would be ignored (`git check-ignore --no-index` on a FILE path, never a directory). Blob state from
`git cat-file blob HEAD:<path>`. The repeatable part of this measurement is the ratchet that now holds it:
`ops/audit-bare-replace.ps1` (blob 93c92ab5525d082b6728b46caaf52d10284f88df), whose `crlf_json_sites` lists the 98
unconverted sites file:line, and they are the census's 98 (18 shifted by the inserted dot-source lines).

The byte runs: a scratch CLONE (a linked worktree would have sent any alert through the MAIN checkout's
send-alert.ps1; the clone's send-alert.ps1 was replaced by a stub that logs and exits 0, so nothing could page).
The conversion was staged in the clone, so an unstaged change is only what a run wrote. For each tool: swap in HEAD's
version, run, record every tracked file `git status --porcelain` shows modified (its CR count, `git diff --numstat`,
BOM), put the outputs back; then the converted version, the same. Each arm starts from `git checkout -- .` excluding
the swapped tool. Libraries read: lib/lf-write.ps1 blob db0898e5501dbd48f46ccbb8de5e7471ec467dfa, lib/atomic-write.ps1
blob 7d8acd0e575ce14921f685c777b89d0c63df5338.

## 2. What went wrong the first time, and why the numbers above are the second run

The first byte run listed changed files with `git diff --name-only`. git normalises CRLF before it compares, so a
rewrite whose content did not change is not listed there, though `git status` shows it ` M`: exactly the defect under
measurement, made invisible by the instrument (memory `crlf-flip-is-invisible-in-git-diff`). Its "clean" rows were
therefore unproven, and the files those runs dirtied were never restored, so they could carry into the next run. It
was found when an ad-hoc check of audit-row-age -Baseline showed ` M` with an empty numstat. The second run reads
`git status --porcelain` and resets before each arm; it is the one reported. Its content rows agree with the first
run's to the line counts.

A second slip, in the same ad-hoc check: `[IO.File]` resolved a relative path against the process directory, not
`Push-Location`, so the check ran HEAD's tool in both arms. The harness used absolute paths throughout and was not
affected; the ad-hoc result was discarded.

Also found by these runs and fixed in the same change: `measure-cheapest-selection` wrote the tracked
`design/MEASURE-cheapest-selection.md` with CRLF in BOTH arms (63 CR), a plain-text Set-Content outside the JSON
class; converted. Found and NOT fixed: `meal-prep/engine/cost-recipes.ps1` writes `db/cost-flags.txt` (tracked) with
plain-text Set-Content, 10 CR and an empty diff, seen while rebaselining golden-test.

## 2a. One row per case per arm

An arm with no row here wrote no tracked file (the old arm's only change was the swapped tool itself). `rc` is the
tool's exit code; several audits exit 1 or 3 on this seeded board for reasons of their own, which is irrelevant to the
bytes they wrote.

| tool | arm | rc | tracked file written | CR | content diff | verdict |
|---|---|---|---|---|---|---|
| `grocery/aisle-test.ps1` | new | 0 | (none) | 0 |  | clean |
| `grocery/audit-ad-forecast.ps1` | new | 0 | (none) | 0 |  | clean |
| `grocery/audit-ad-forecast.ps1` | new -Accept | 0 | (none) | 0 |  | clean |
| `grocery/audit-asof-evidence.ps1` | old | 3 | `grocery/out/asof-evidence.json` | 26 | +1/-13 | CRLF |
| `grocery/audit-asof-evidence.ps1` | new | 3 | `grocery/out/asof-evidence.json` | 0 | +1/-13 | content |
| `grocery/audit-band-censorship.ps1` | new | 3 | (none) | 0 |  | clean |
| `grocery/audit-band-censorship.ps1` | new -Accept | 3 | (none) | 0 |  | clean |
| `grocery/audit-basis-reconcile.ps1` | old | 0 | `grocery/out/basis-reconcile.json` | 12 | +1/-1 | CRLF |
| `grocery/audit-basis-reconcile.ps1` | new | 0 | `grocery/out/basis-reconcile.json` | 0 | +1/-1 | content |
| `grocery/audit-board-mojibake.ps1` | new | 0 | (none) | 0 |  | clean |
| `grocery/audit-board-mojibake.ps1` | old -Accept | 0 | `grocery/out/board-mojibake-baseline.json` | 5 | +1/-1 | CRLF |
| `grocery/audit-board-mojibake.ps1` | new -Accept | 0 | `grocery/out/board-mojibake-baseline.json` | 0 | +1/-1 | content |
| `grocery/audit-board-reconciliation.ps1` | old | 0 | `grocery/out/board-reconciliation.json` | 8 |  | CRLF-ONLY |
| `grocery/audit-board-reconciliation.ps1` | new | 0 | (none) | 0 |  | clean |
| `grocery/audit-capture-eviction.ps1` | new | 3 | (none) | 0 |  | clean |
| `grocery/audit-commodity-dupes.ps1` | old | 0 | `grocery/out/commodity-dupes.json` | 18 | +1/-1 | CRLF |
| `grocery/audit-commodity-dupes.ps1` | new | 0 | `grocery/out/commodity-dupes.json` | 0 | +1/-1 | content |
| `grocery/audit-everyday-mismatch.ps1` | old | 1 | `grocery/out/everyday-mismatches.json` | 639 |  | CRLF-ONLY |
| `grocery/audit-everyday-mismatch.ps1` | new | 1 | (none) | 0 |  | clean |
| `grocery/audit-ff-missing-products.ps1` | old | 0 | `grocery/out/ff-missing-products.json` | 62 | +18/-90 | CRLF |
| `grocery/audit-ff-missing-products.ps1` | new | 0 | `grocery/out/ff-missing-products.json` | 0 | +18/-90 | content |
| `grocery/audit-instore-channel.ps1` | old | 0 | `grocery/out/instore-channel-doubt.json` | 3005 | +4/-4 | CRLF |
| `grocery/audit-instore-channel.ps1` | new | 0 | `grocery/out/instore-channel-doubt.json` | 0 | +4/-4 | content |
| `grocery/audit-match-contested.ps1` | old | 0 | `grocery/out/match-contested.json` | 2159 | +782/-878 | CRLF |
| `grocery/audit-match-contested.ps1` | new | 0 | `grocery/out/match-contested.json` | 0 | +782/-878 | content |
| `grocery/audit-null-rate.ps1` | new | 0 | (none) | 0 |  | clean |
| `grocery/audit-null-rate.ps1` | old -Update | 0 | `grocery/null-rate-baseline.json` | 298 | +129/-145 | CRLF |
| `grocery/audit-null-rate.ps1` | new -Update | 0 | `grocery/null-rate-baseline.json` | 0 | +129/-145 | content |
| `grocery/audit-pack-basis.ps1` | old | 0 | `grocery/out/pack-basis-audit.json` | 9 | +1/-1 | CRLF |
| `grocery/audit-pack-basis.ps1` | new | 0 | `grocery/out/pack-basis-audit.json` | 0 | +1/-1 | content |
| `grocery/audit-row-age.ps1` | new | 0 | (none) | 0 |  | clean |
| `grocery/audit-row-age.ps1` | old -Baseline | 0 | `grocery/out/row-age-baseline.json` | 30 |  | CRLF-ONLY |
| `grocery/audit-row-age.ps1` | new -Baseline | 0 | (none) | 0 |  | clean |
| `grocery/audit-sale-fallback.ps1` | old | 2 | `grocery/sale-fallback-ownership.json` | 34 | +28/-36 | CRLF |
| `grocery/audit-sale-fallback.ps1` | new | 2 | `grocery/sale-fallback-ownership.json` | 0 | +28/-36 | content |
| `grocery/audit-semantic-identity.ps1` | new | 3 | (none) | 0 |  | clean |
| `grocery/audit-store-taxonomy.ps1` | new | 0 | (none) | 0 |  | clean |
| `grocery/audit-tile-integrity.ps1` | new | 0 | (none) | 0 |  | clean |
| `grocery/audit-tile-integrity.ps1` | old -Tighten | 0 | `grocery/out/tile-integrity-baseline.json` | 0 | +2/-2 | content |
| `grocery/audit-tile-integrity.ps1` | new -Tighten | 0 | `grocery/out/tile-integrity-baseline.json` | 0 | +2/-2 | content |
| `grocery/audit-unit-basis-outlier.ps1` | old | 0 | `grocery/out/basis-outliers.json` | 671 | +1/-1 | CRLF |
| `grocery/audit-unit-basis-outlier.ps1` | new | 0 | `grocery/out/basis-outliers.json` | 0 | +1/-1 | content |
| `grocery/build-drift-chips.ps1` | new | 1 | (none) | 0 |  | clean |
| `grocery/build-regression-baseline.ps1` | old | 0 | `grocery/regression-baseline.json` | 227 | +39/-341 | CRLF |
| `grocery/build-regression-baseline.ps1` | new | 0 | `grocery/regression-baseline.json` | 0 | +39/-341 | content |
| `grocery/explain-coverage-gap.ps1` | old | 0 | `grocery/out/coverage-gap-explained.json` | 93 | +38/-94 | CRLF |
| `grocery/explain-coverage-gap.ps1` | new | 0 | `grocery/out/coverage-gap-explained.json` | 0 | +38/-94 | content |
| `grocery/generate-board-overrides.ps1` | new | 1 | (none) | 0 |  | clean |
| `grocery/measure-cheapest-selection.ps1` | old | 0 | `design/MEASURE-cheapest-selection.md` | 63 | +37/-40 | CRLF |
| `grocery/measure-cheapest-selection.ps1` | old | 0 | `grocery/out/cheapest-selection-report.json` | 1 | +1/-1 | CRLF |
| `grocery/measure-cheapest-selection.ps1` | new | 0 | `design/MEASURE-cheapest-selection.md` | 0 | +37/-40 | content |
| `grocery/measure-cheapest-selection.ps1` | new | 0 | `grocery/out/cheapest-selection-report.json` | 0 | +1/-1 | content |
| `grocery/triage-coverage-gaps.ps1` | new | 1 | (none) | 0 |  | clean |
| `grocery/triage-outofband.ps1` | new | 1 | (none) | 0 |  | clean |
| `grocery/triage-unpriced.ps1` | new | 1 | (none) | 0 |  | clean |
| `meal-prep/pipeline/audit-schema-constraints.ps1` | new | 0 | (none) | 0 |  | clean |
| `meal-prep/engine/cost-recipes.ps1` | old | 0 | `meal-prep/db/costed.json` | 151814 | +216/-216 | CRLF |
| `meal-prep/engine/cost-recipes.ps1` | old | 0 | `meal-prep/db/costed.stamp.json` | 37 | +5/-5 | CRLF |
| `meal-prep/engine/cost-recipes.ps1` | new | 0 | `meal-prep/db/costed.json` | 0 | +216/-216 | content |
| `meal-prep/engine/cost-recipes.ps1` | new | 0 | `meal-prep/db/costed.stamp.json` | 0 | +5/-5 | content |

## 3. One row per write site

All 228 live production sites, TRACKED first. Line numbers are at the census tree (before this conversion inserted
its dot-source lines). `probe` is the concrete path the verdict was read against.

| site | target expression | verdict | probe | blob at HEAD | writer now |
|---|---|---|---|---|---|
| `grocery/aisle-test.ps1:313` | `$OutFile` | TRACKED | grocery/out/aisle-test.json | `grocery/out/aisle-test.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/apply-cell-quarantine.ps1:55` | `$ProductUrlsFile` | TRACKED | grocery/product-urls.json | `grocery/product-urls.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/apply-cell-quarantine.ps1:99` | `$ProductUrlsFile` | TRACKED | grocery/product-urls.json | `grocery/product-urls.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/audit-ad-forecast.ps1:438` | `$Baseline` | TRACKED | grocery/ad-forecast-baseline.json | `grocery/ad-forecast-baseline.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-ad-forecast.ps1:472` | `$Baseline` | TRACKED | grocery/ad-forecast-baseline.json | `grocery/ad-forecast-baseline.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-ad-forecast.ps1:501` | `$Baseline` | TRACKED | grocery/ad-forecast-baseline.json | `grocery/ad-forecast-baseline.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-asof-evidence.ps1:304` | `$outPath` | TRACKED | grocery/out/asof-evidence.json | `grocery/out/asof-evidence.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-band-censorship.ps1:627` | `$outFile` | TRACKED | grocery/out/band-censorship.json | `grocery/out/band-censorship.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-band-censorship.ps1:651` | `$blF` | TRACKED | grocery/out/band-censorship-baseline.json | `grocery/out/band-censorship-baseline.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-basis-reconcile.ps1:282` | `$rep` | TRACKED | grocery/out/basis-reconcile.json | `grocery/out/basis-reconcile.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-board-mojibake.ps1:285` | `$blF` | TRACKED | grocery/out/board-mojibake-baseline.json | `grocery/out/board-mojibake-baseline.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-board-mojibake.ps1:303` | `$blF` | TRACKED | grocery/out/board-mojibake-baseline.json | `grocery/out/board-mojibake-baseline.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-board-reconciliation.ps1:235` | `$outF` | TRACKED | grocery/out/board-reconciliation.json | `grocery/out/board-reconciliation.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-capture-eviction.ps1:281` | `$outFile` | TRACKED | grocery/out/capture-evictions.json | `grocery/out/capture-evictions.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-commodity-dupes.ps1:217` | `(Join-Path $OutDir 'commodity-dupes.json')` | TRACKED | grocery/out/commodity-dupes.json | `grocery/out/commodity-dupes.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-everyday-mismatch.ps1:180` | `$outF` | TRACKED | grocery/out/everyday-mismatches.json | `grocery/out/everyday-mismatches.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-ff-missing-products.ps1:98` | `(Join-Path $root 'out\ff-missing-products.json')` | TRACKED | grocery/out/ff-missing-products.json | `grocery/out/ff-missing-products.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-ghost-drift.ps1:297` | `(Join-Path $root 'out\ghost-drift-recipes.json')` | TRACKED | grocery/out/ghost-drift-recipes.json | `grocery/out/ghost-drift-recipes.json` noBOM / no trailer / CR 0 | Write-TcAtomicFile -Lf -NoBom -NoNewline |
| `grocery/audit-ghost-drift.ps1:343` | `$manifestPath` | TRACKED | grocery/ghost-tool-manifest.json | `grocery/ghost-tool-manifest.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-instore-channel.ps1:220` | `(Join-Path $OutDir 'instore-channel-doubt.json')` | TRACKED | grocery/out/instore-channel-doubt.json | `grocery/out/instore-channel-doubt.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-match-contested.ps1:95` | `$out` | TRACKED | grocery/out/match-contested.json | `grocery/out/match-contested.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-null-rate.ps1:204` | `$BASELINE` | TRACKED | grocery/null-rate-baseline.json | `grocery/null-rate-baseline.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-pack-basis.ps1:194` | `$rep` | TRACKED | grocery/out/pack-basis-audit.json | `grocery/out/pack-basis-audit.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-row-age.ps1:425` | `$baselinePath` | TRACKED | grocery/out/row-age-baseline.json | `grocery/out/row-age-baseline.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-sale-fallback.ps1:364` | `$ledgerPath` | TRACKED | grocery/sale-fallback-ownership.json | `grocery/sale-fallback-ownership.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/audit-search-links.ps1:258` | `$baseF` | TRACKED | grocery/search-link-baseline.json | `grocery/search-link-baseline.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-search-links.ps1:282` | `$reportF` | TRACKED | grocery/out/search-links-report.json | `grocery/out/search-links-report.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-semantic-identity.ps1:469` | `$rp` | TRACKED | grocery/out/semantic-findings.json | `grocery/out/semantic-findings.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-shelf-signal.ps1:206` | `$rep` | TRACKED | grocery/out/shelf-signal.json | `grocery/out/shelf-signal.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-store-taxonomy.ps1:372` | `$rf` | TRACKED | grocery/out/taxonomy-disagreements-*.json | `grocery/out/taxonomy-disagreements-2026-10-02.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-tile-integrity.ps1:372` | `$blF` | TRACKED | grocery/out/tile-integrity-baseline.json | `grocery/out/tile-integrity-baseline.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/audit-unit-basis-outlier.ps1:719` | `$outFile` | TRACKED | grocery/out/basis-outliers.json | `grocery/out/basis-outliers.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/brands/assemble-board-brands.ps1:81` | `(Join-Path $here '..\out\brands\brands-board.json')` | TRACKED | grocery/out/brands/brands-board.json | `grocery/out/brands/brands-board.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/brands/gen-browser-cfg.ps1:20` | `$OutPath` | TRACKED | grocery/brands/browser-cfg.json | `grocery/brands/browser-cfg.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/brands/pull-ff-brands-batch.ps1:68` | `$OutPath` | TRACKED | grocery/out/brands/out-ff-buckets-b.json | `grocery/out/brands/out-ff-buckets-b.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/build-aldi-regular.ps1:985` | `$outFile` | TRACKED | grocery/out/regular/aldi-regular-*.json | `grocery/out/regular/aldi-regular-2026-10-02.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/build-aldi-regular.ps1:988` | `$rejFile` | TRACKED | grocery/out/aldi-rejects-*.json | `grocery/out/aldi-rejects-2026-10-02.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/build-drift-chips.ps1:91` | `$out` | TRACKED | grocery/out/url-inputs/drift-*.json | `grocery/out/url-inputs/drift-walmart.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/build-fareway-regular.ps1:664` | `$regPath` | TRACKED | grocery/out/regular/fareway-regular-*.json | `grocery/out/regular/fareway-regular-2026-10-02.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/build-fareway-regular.ps1:670` | `(Join-Path $uiDir 'store-fareway1-urls.json')` | TRACKED | grocery/out/url-inputs/store-fareway1-urls.json | `grocery/out/url-inputs/store-fareway1-urls.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/build-freezer-data.ps1:102` | `$outPath` | TRACKED | grocery/out/freezer-data.json | `grocery/out/freezer-data.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/build-regression-baseline.ps1:58` | `$file` | TRACKED | grocery/regression-baseline.json | `grocery/regression-baseline.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/build-sams-deals.ps1:1569` | `$outFile` | TRACKED | grocery/out/sams/sams-deals-*.json | `grocery/out/sams/sams-deals-2026-10-02.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/build-sams-deals.ps1:1599` | `$rj` | TRACKED | grocery/out/sams/sams-rejects-*.json | `grocery/out/sams/sams-rejects-2026-10-02.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/build-walmart-deals.ps1:707` | `$outFile` | TRACKED | grocery/out/regular/walmart-regular-*.json | `grocery/out/regular/walmart-regular-2026-10-02.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/build-walmart-deals.ps1:731` | `$rj` | TRACKED | grocery/out/walmart-rejects-*.json | `grocery/out/walmart-rejects-2026-10-02.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/carry-forward-regular.ps1:205` | `$newF.FullName` | TRACKED | grocery/out/regular/*-regular-*.json | `grocery/out/regular/walmart-regular-2026-10-02.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/cell-quarantine-lib.ps1:417` | `$path` | TRACKED | grocery/out/cell-quarantine.json | `grocery/out/cell-quarantine.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/check-ad-cycles.ps1:3477` | `$tmpF` | TRACKED | grocery/out/alerted-flags.json | `grocery/out/alerted-flags.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf (temp+move folded in) |
| `grocery/check-ad-cycles.ps1:883` | `$ScheduleFile` | TRACKED | grocery/ad-schedule.json | `grocery/ad-schedule.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/derive-recipe-floors.ps1:189` | `(Join-Path $outDir 'recipe-floors-report.json')` | TRACKED | grocery/out/recipe-floors-report.json | `grocery/out/recipe-floors-report.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/derive-recipe-floors.ps1:190` | `(Join-Path $outDir 'recipe-floors-proposed.json')` | TRACKED | grocery/out/recipe-floors-proposed.json | `grocery/out/recipe-floors-proposed.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/discover-hyvee.ps1:344` | `$outF` | TRACKED | grocery/out/hyvee-discovery.json | `grocery/out/hyvee-discovery.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/explain-coverage-gap.ps1:53` | `(Join-Path $root 'out\coverage-gap-explained.json')` | TRACKED | grocery/out/coverage-gap-explained.json | `grocery/out/coverage-gap-explained.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/export-identity-eval.ps1:164` | `(Join-Path $sd 'mine-labelled.json')` | TRACKED | sidecar/data/mine-labelled.json | `sidecar/data/mine-labelled.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/fix-links-ff.ps1:163` | `$planPath` | TRACKED | grocery/out/ff-link-plan.json | `grocery/out/ff-link-plan.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/fix-links-ff.ps1:81` | `$puPath` | TRACKED | grocery/product-urls.json | `grocery/product-urls.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/generate-board-overrides.ps1:218` | `(Join-Path $root 'board-price-overrides.json')` | TRACKED | grocery/board-price-overrides.json | `grocery/board-price-overrides.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/heal-degraded-sizes.ps1:123` | `$newF.FullName` | TRACKED | grocery/out/regular/*-regular-*.json | `grocery/out/regular/walmart-regular-2026-10-02.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/heal-ff-missing-products.ps1:90` | `$curF.FullName` | TRACKED | grocery/out/regular/family-fare-regular-*.json | `grocery/out/regular/family-fare-regular-2026-10-02.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/heal-ff-missing-products.ps1:92` | `(Join-Path $root 'out\ff-heal-expected.json')` | TRACKED | grocery/out/ff-heal-expected.json | `grocery/out/ff-heal-expected.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/heal-missing-products.ps1:140` | `$curF.FullName` | TRACKED | grocery/out/regular/*-regular-*.json | `grocery/out/regular/walmart-regular-2026-10-02.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/heal-missing-products.ps1:159` | `$expF` | TRACKED | grocery/out/heal-expected.json | `grocery/out/heal-expected.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/heal-mojibake.ps1:104` | `$puPath` | TRACKED | grocery/product-urls.json | `grocery/product-urls.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/heal-mojibake.ps1:46` | `$f.FullName` | TRACKED | grocery/out/regular/*-regular-*.json | `grocery/out/regular/walmart-regular-2026-10-02.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf -KeepShape |
| `grocery/heal-mojibake.ps1:80` | `$rbPath` | TRACKED | grocery/out/recipe-board-everyday.json | `grocery/out/recipe-board-everyday.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/import-instacart-batch.ps1:215` | `$outFile` | TRACKED | grocery/out/regular/*-regular-*.json | `grocery/out/regular/walmart-regular-2026-10-02.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/import-instacart-batch.ps1:216` | `$outFile` | TRACKED | grocery/out/regular/*-regular-*.json | `grocery/out/regular/walmart-regular-2026-10-02.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/import-sams-prices.ps1:198` | `$regF.FullName` | TRACKED | grocery/out/regular/sams-regular-*.json | `grocery/out/regular/sams-regular-2026-08-01.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/import-walmart-batch.ps1:472` | `$prevR.FullName` | TRACKED | grocery/out/regular/walmart-regular-*.json | `grocery/out/regular/walmart-regular-2026-10-02.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/import-walmart-batch.ps1:481` | `$rf` | TRACKED | grocery/out/walmart-batch-rejects-*.json | `grocery/out/walmart-batch-rejects-2026-07-31.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/import-walmart-batch.ps1:608` | `$outFile` | TRACKED | grocery/out/regular/walmart-regular-*.json | `grocery/out/regular/walmart-regular-2026-10-02.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/import-walmart-batch.ps1:610` | `$outFile` | TRACKED | grocery/out/regular/walmart-regular-*.json | `grocery/out/regular/walmart-regular-2026-10-02.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/import-walmart-batch.ps1:612` | `(Join-Path $outRootDir ("out\walmart-batch-rejects-$today...` | TRACKED | grocery/out/walmart-batch-rejects-*.json | `grocery/out/walmart-batch-rejects-2026-07-31.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/import-walmart-batch.ps1:645` | `$idsFile` | TRACKED | grocery/out/staples500/walmart-itemids.json | `grocery/out/staples500/walmart-itemids.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/measure-cheapest-selection.ps1:403` | `$OutFile` | TRACKED | grocery/out/cheapest-selection-report.json | `grocery/out/cheapest-selection-report.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/merge-candidates.ps1:70` | `(Join-Path $OutDir 'candidates-500.json')` | TRACKED | grocery/out/staples500/candidates-500.json | `grocery/out/staples500/candidates-500.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/merge-product-urls.ps1:115` | `$outFile` | TRACKED | grocery/product-urls.json | `grocery/product-urls.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/notify-item-added.ps1:202` | `$stateFile` | TRACKED | grocery/notify-known-ids.json | `grocery/notify-known-ids.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/notify-item-added.ps1:321` | `$stateFile` | TRACKED | grocery/notify-known-ids.json | `grocery/notify-known-ids.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/prime-batch-headless.ps1:83` | `$outFile` | TRACKED | grocery/out/regular/*-regular-*.json | `grocery/out/regular/walmart-regular-2026-10-02.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/prime-batch-headless.ps1:85` | `$outFile` | TRACKED | grocery/out/regular/*-regular-*.json | `grocery/out/regular/walmart-regular-2026-10-02.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/promote-verdicts.ps1:334` | `$cPath` | TRACKED | grocery/commodities.json | `grocery/commodities.json` noBOM / LF / CR 0 | Write-TcAtomicFile -Lf -NoBom |
| `grocery/promote-verdicts.ps1:339` | `$provPath` | TRACKED | grocery/exclude-provenance.json | `grocery/exclude-provenance.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/prune-bad-links.ps1:111` | `$puFile` | TRACKED | grocery/product-urls.json | `grocery/product-urls.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/pull-fareway-ads.ps1:209` | `(Join-Path $fwDir "fareway-ad-manifest-$asofS.json")` | TRACKED | grocery/out/fareway/fareway-ad-manifest-*.json | `grocery/out/fareway/fareway-ad-manifest-2026-09-20.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/pull-grocery-ads.ps1:386` | `$file` | TRACKED | grocery/out/ads-*.json | `grocery/out/ads-2026-09-30.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/pull-regular-bakers-api.ps1:1665` | `$file` | TRACKED | grocery/out/regular/bakers-regular-*.json | `grocery/out/regular/bakers-regular-2026-10-02.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/pull-regular-hyvee.ps1:2092` | `$file` | TRACKED | grocery/out/regular/hyvee-regular-*.json | `grocery/out/regular/hyvee-regular-2026-10-02.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/purge-bad-lows.ps1:85` | `$path` | TRACKED | grocery/price-history.json | `grocery/price-history.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/purge-verdict-lows.ps1:476` | `(Join-Path $OutDir 'purge-verdict-lows-unresolved.json')` | TRACKED | grocery/out/purge-verdict-lows-unresolved.json | `grocery/out/purge-verdict-lows-unresolved.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/purge-verdict-lows.ps1:489` | `$tmp` | TRACKED | grocery/price-history.json (via $HistoryFile.tmp) | `grocery/price-history.json` BOM / LF / CR 0 | Write-TcLfFile on the temp (re-parse kept) |
| `grocery/refresh-bakers-links.ps1:75` | `$puFile` | TRACKED | grocery/product-urls.json | `grocery/product-urls.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/refresh-hyvee-links.ps1:119` | `$puF` | TRACKED | grocery/product-urls.json | `grocery/product-urls.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/refresh-sams-verified.ps1:194` | `$outPath` | TRACKED | grocery/out/regular/sams-regular-*.json | `grocery/out/regular/sams-regular-2026-08-01.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/register-batch.ps1:78` | `(Join-Path $root 'commodities.json')` | TRACKED | grocery/commodities.json | `grocery/commodities.json` noBOM / LF / CR 0 | Write-TcAtomicFile -Lf -NoBom |
| `grocery/register-batch.ps1:79` | `(Join-Path $root 'categories.json')` | TRACKED | grocery/categories.json | `grocery/categories.json` noBOM / LF / CR 0 | Write-TcAtomicFile -Lf -NoBom |
| `grocery/register-batch.ps1:80` | `(Join-Path $root 'commodity-search.json')` | TRACKED | grocery/commodity-search.json | `grocery/commodity-search.json` noBOM / LF / CR 0 | Write-TcAtomicFile -Lf -NoBom |
| `grocery/repair-asof-evidence.ps1:127` | `$f.FullName` | TRACKED | grocery/out/regular/*-regular-*.json | `grocery/out/regular/walmart-regular-2026-10-02.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/repair-multipack-sizes.ps1:205` | `$file.FullName` | TRACKED | grocery/out/regular/*-regular-*.json | `grocery/out/regular/walmart-regular-2026-10-02.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/resolve-hyvee-links.ps1:380` | `$puF` | TRACKED | grocery/product-urls.json | `grocery/product-urls.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/select-fareway-shop.ps1:767` | `$Out` | TRACKED | grocery/out/fareway/fareway-shop-*.json | `grocery/out/fareway/fareway-shop-2026-10-02.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/stamp-board-pu.ps1:70` | `$pf` | TRACKED | grocery/product-urls.json | `grocery/product-urls.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/stamp-fareway-instore.ps1:59` | `$File` | TRACKED | grocery/out/regular/fareway-regular-*.json | `grocery/out/regular/fareway-regular-2026-10-02.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/sync-browser-links.ps1:108` | `$puF` | TRACKED | grocery/product-urls.json | `grocery/product-urls.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `grocery/transform-store-links.ps1:30` | `$outFile` | TRACKED | grocery/out/url-inputs/store-*-urls.json | `grocery/out/url-inputs/store-walmart2-urls.json` noBOM / no trailer / CR 0 | Write-TcAtomicFile -Lf -KeepShape |
| `grocery/triage-coverage-gaps.ps1:97` | `(Join-Path $OutDir 'gap-triage.json')` | TRACKED | grocery/out/gap-triage.json | `grocery/out/gap-triage.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/triage-outofband.ps1:45` | `(Join-Path $OutDir 'outofband-triage.json')` | TRACKED | grocery/out/outofband-triage.json | `grocery/out/outofband-triage.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/triage-unpriced.ps1:63` | `(Join-Path $OutDir 'unpriced-triage.json')` | TRACKED | grocery/out/unpriced-triage.json | `grocery/out/unpriced-triage.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/update-history.ps1:362` | `$histTmp` | TRACKED | grocery/price-history.json | `grocery/price-history.json` BOM / LF / CR 0 | Write-TcLfFile on the temp (re-parse kept) |
| `grocery/validate-fills.ps1:90` | `$out` | TRACKED | grocery/out/newitem-accepted.json | `grocery/out/newitem-accepted.json` BOM / LF / CR 0 | Write-TcLfFile |
| `grocery/verify-apply.ps1:140` | `$tmpS` | TRACKED | grocery/verdict-suppressions.json | `grocery/verdict-suppressions.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf (temp+move folded in) |
| `grocery/withdraw-stale-link.ps1:42` | `$puFile` | TRACKED | grocery/product-urls.json | `grocery/product-urls.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `lib/chain-verdict-lib.ps1:161` | `$path` | TRACKED | grocery/out/chain-verdict.json | `grocery/out/chain-verdict.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `meal-prep/engine/cost-recipes.ps1:706` | `$costedPath` | TRACKED | meal-prep/db/costed.json | `meal-prep/db/costed.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `meal-prep/engine/cost-recipes.ps1:758` | `$stampPath` | TRACKED | meal-prep/db/costed.stamp.json | `meal-prep/db/costed.stamp.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `meal-prep/engine/seed-golden-fixture.ps1:103` | `(Join-Path $fin 'db\ingredients.json')` | TRACKED | meal-prep/engine/regression-inputs/golden/inputs/db/ingredients.json | `meal-prep/engine/regression-inputs/golden/inputs/db/ingredients.json` BOM / LF / CR 0 | Write-TcLfFile |
| `meal-prep/engine/seed-golden-fixture.ps1:109` | `(Join-Path $fin 'db\densities.json')` | TRACKED | meal-prep/engine/regression-inputs/golden/inputs/db/densities.json | `meal-prep/engine/regression-inputs/golden/inputs/db/densities.json` BOM / LF / CR 0 | Write-TcLfFile |
| `meal-prep/engine/seed-golden-fixture.ps1:118` | `(Join-Path $fin 'db\label-prices.json')` | TRACKED | meal-prep/engine/regression-inputs/golden/inputs/db/label-prices.json | `meal-prep/engine/regression-inputs/golden/inputs/db/label-prices.json` BOM / LF / CR 0 | Write-TcLfFile |
| `meal-prep/engine/seed-golden-fixture.ps1:128` | `(Join-Path $fin 'grocery-out\comparison-2026-01-01.json')` | TRACKED | meal-prep/engine/regression-inputs/golden/inputs/grocery-out/comparison-2026-01-01.json | `meal-prep/engine/regression-inputs/golden/inputs/grocery-out/comparison-2026-01-01.json` BOM / LF / CR 0 | Write-TcLfFile |
| `meal-prep/engine/seed-golden-fixture.ps1:134` | `(Join-Path $fin 'grocery-out\recipe-board.json')` | TRACKED | meal-prep/engine/regression-inputs/golden/inputs/grocery-out/recipe-board.json | `meal-prep/engine/regression-inputs/golden/inputs/grocery-out/recipe-board.json` BOM / LF / CR 0 | Write-TcLfFile |
| `meal-prep/engine/seed-golden-fixture.ps1:142` | `(Join-Path $fin 'grocery-out\smp-feed.json')` | TRACKED | meal-prep/engine/regression-inputs/golden/inputs/grocery-out/smp-feed.json | `meal-prep/engine/regression-inputs/golden/inputs/grocery-out/smp-feed.json` BOM / LF / CR 0 | Write-TcLfFile |
| `meal-prep/engine/seed-golden-fixture.ps1:77` | `(Join-Path $fin "db\recipes\$synthSlug.json")` | TRACKED | meal-prep/engine/regression-inputs/golden/inputs/db/recipes/zz-synthetic-flag-cases.json | `meal-prep/engine/regression-inputs/golden/inputs/db/recipes/zz-synthetic-flag-cases.json` BOM / LF / CR 0 | Write-TcLfFile |
| `meal-prep/normalize-recipe-ids.ps1:77` | `$dbFile` | TRACKED | meal-prep/recipes-db.json | `meal-prep/recipes-db.json` noBOM / LF / CR 0 | Write-TcAtomicFile -Lf -NoBom |
| `meal-prep/pipeline/audit-schema-constraints.ps1:366` | `$baselinePath` | TRACKED | meal-prep/db/schema-constraint-baseline.json | `meal-prep/db/schema-constraint-baseline.json` BOM / LF / CR 0 | Write-TcLfFile |
| `meal-prep/pipeline/propagate-recipes.ps1:525` | `$stampPath` | TRACKED | meal-prep/pipeline/propagate-stamps.json | `meal-prep/pipeline/propagate-stamps.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `meal-prep/pipeline/propagate-recipes.ps1:656` | `$stampPath` | TRACKED | meal-prep/pipeline/propagate-stamps.json | `meal-prep/pipeline/propagate-stamps.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `meal-prep/pipeline/repair-measure-vs-grams.ps1:465` | `(Join-Path $mp 'out\measure-vs-grams-carry.json')` | TRACKED | meal-prep/out/measure-vs-grams-carry.json | `meal-prep/out/measure-vs-grams-carry.json` noBOM / LF / CR 0 | Write-TcLfFile -NoBom |
| `meal-prep/pipeline/repair-scaled-notes.ps1:461` | `(Join-Path $mp 'out\scaled-note-carry.json')` | TRACKED | meal-prep/out/scaled-note-carry.json | `meal-prep/out/scaled-note-carry.json` BOM / LF / CR 0 | Write-TcLfFile |
| `meal-prep/rotate-free-dinners.ps1:216` | `$stateFile` | TRACKED | meal-prep/free-rotation.json | `meal-prep/free-rotation.json` BOM / LF / CR 0 | Write-TcAtomicFile -Lf |
| `.claude/skills/lesson/google-oauth-authorize.ps1:76` | `$tokenFile` | untracked | .claude/skills/lesson/google-oauth-token.json | - | left |
| `.claude/skills/lesson/google-token.ps1:22` | `$tokenFile` | untracked | .claude/skills/lesson/google-oauth-token.json | - | left |
| `.claude/skills/lesson/thriftycrew-oauth-authorize.ps1:76` | `$tokenFile` | untracked | .claude/skills/lesson/thriftycrew-oauth-token.json | - | left |
| `grocery/adpages-lib.ps1:146` | `(Join-Path $Dir 'ad-window.json')` | untracked | grocery/out/<store>/ad-window.json (0 tracked anywhere) | - | left |
| `grocery/apply-cell-quarantine.ps1:49` | `$boardF` | ignored | grocery/out/comparison-<date>.json (plan.board_file) | - | left |
| `grocery/apply-cell-quarantine.ps1:82` | `$boardF` | ignored | grocery/out/comparison-<date>.json (plan.board_file) | - | left |
| `grocery/audit-asof-evidence.ps1:321` | `$basePath` | untracked | grocery/out/asof-evidence-baseline.json | - | left |
| `grocery/audit-band-censorship.ps1:543` | `$ReplayRows` | caller-path | -ReplayRows <path> | - | left |
| `grocery/audit-board-consistency.ps1:211` | `(Join-Path $OutDir 'consistency-report.json')` | ignored | grocery/out/consistency-report.json | - | left |
| `grocery/audit-capture-eviction.ps1:288` | `$stampFile` | ignored | grocery/out/capture-evictions-stamp.json | - | left |
| `grocery/audit-coverage-gaps.ps1:711` | `(Join-Path $ReportDir 'coverage-gaps.json')` | ignored | grocery/out/coverage-gaps.json | - | left |
| `grocery/audit-coverage-regression.ps1:113` | `(Join-Path $OutDir 'coverage-regression.json')` | ignored | grocery/out/coverage-regression.json | - | left |
| `grocery/audit-ghost-drift.ps1:419` | `$allowPath` | untracked | grocery/ghost-drift-allowlist.json | - | left |
| `grocery/audit-known-wrong.ps1:449` | `(Join-Path $outDir 'known-wrong-report.json')` | untracked | grocery/out/known-wrong-report.json | - | left |
| `grocery/audit-links.ps1:116` | `(Join-Path $outDir 'link-audit.json')` | ignored | grocery/out/link-audit.json | - | left |
| `grocery/audit-name-drift.ps1:286` | `(Join-Path $out 'name-drift.json')` | ignored | grocery/out/name-drift.json | - | left |
| `grocery/audit-sale-fallback.ps1:373` | `(Join-Path $OutDir 'sale-fallback-gaps.json')` | ignored | grocery/out/sale-fallback-gaps.json | - | left |
| `grocery/audit-semantic-identity.ps1:300` | `(Join-Path $sdData 'board-pairs.json')` | ignored | sidecar/data/board-pairs.json | - | left |
| `grocery/audit-semantic-identity.ps1:312` | `(Join-Path $sdData 'commodity-defs.json')` | ignored | sidecar/data/commodity-defs.json | - | left |
| `grocery/audit-semantic-identity.ps1:342` | `(Join-Path $sdData 'corpus-current.json')` | ignored | sidecar/data/corpus-current.json | - | left |
| `grocery/audit-store-coverage.ps1:84` | `(Join-Path $OutDir 'store-coverage-report.json')` | ignored | grocery/out/store-coverage-report.json | - | left |
| `grocery/audit-tile-integrity.ps1:320` | `(Join-Path $OutDir 'tile-integrity.json')` | ignored | grocery/out/tile-integrity.json | - | left |
| `grocery/audit-tile-integrity.ps1:336` | `(Join-Path $OutDir 'tile-integrity.json')` | ignored | grocery/out/tile-integrity.json | - | left |
| `grocery/audit-tile-integrity.ps1:483` | `(Join-Path $OutDir 'tile-integrity.json')` | ignored | grocery/out/tile-integrity.json | - | left |
| `grocery/brands/make-config.ps1:26` | `$OutPath` | caller-path | -OutPath <path> (mandatory) | - | left |
| `grocery/build-arrivals-docket.ps1:586` | `$OutFile` | ignored | grocery/out/arrivals-docket.json | - | left |
| `grocery/compare-deals.ps1:1023` | `(Join-Path $OutDir ("$candPfx-"+$today+".json"))` | ignored | grocery/out/comparison-candidates-<date>.json | - | left |
| `grocery/compare-deals.ps1:1069` | `$pwPath` | ignored | grocery/out/provenance-withheld-<date>.json | - | left |
| `grocery/compare-deals.ps1:1191` | `(Join-Path $OutDir ("$flagPfx-"+$today+".json"))` | ignored | grocery/out/comparison-flagged-<date>.json | - | left |
| `grocery/compare-deals.ps1:1200` | `$file` | ignored | grocery/out/comparison-<date>.json | - | left |
| `grocery/export-identity-eval.ps1:198` | `(Join-Path $sd 'negatives-gold.json')` | ignored | sidecar/data/negatives-gold.json | - | left |
| `grocery/export-identity-eval.ps1:203` | `(Join-Path $sd 'eval-positives.json')` | ignored | sidecar/data/eval-positives.json | - | left |
| `grocery/export-identity-eval.ps1:212` | `(Join-Path $sd 'mine-products.json')` | ignored | sidecar/data/mine-products.json | - | left |
| `grocery/import-walmart-batch.ps1:615` | `$qf` | untracked | grocery/out/walmart-batch-needs-seller-<date>.json | - | left |
| `grocery/notify-item-added.ps1:327` | `$sentFile` | untracked | grocery/notify-sent-log.json | - | left |
| `grocery/pull-bakers.ps1:105` | `(Join-Path $OutDir 'meta.json')` | ignored | grocery/out/bakers/meta.json | - | left |
| `grocery/pull-regular-bakers-api.ps1:1421` | `$refFile` | ignored | grocery/out/kroger-api-eval/* | - | left |
| `grocery/pull-regular-bakers-api.ps1:1613` | `$pfile` | untracked | grocery/out/throttled/bakers-<date>.throttled.json (family last committed 2026-07-26) | - | left |
| `grocery/pull-regular-hyvee.ps1:2050` | `$pfile` | untracked | grocery/out/throttled/hyvee-<date>.throttled.json (family last committed 2026-07-26) | - | left |
| `grocery/recipe-overlay.ps1:301` | `(Join-Path $out 'recipe-board.json')` | ignored | grocery/out/recipe-board.json | - | left |
| `grocery/recover-sams-quarantine.ps1:101` | `$rj` | untracked | grocery/out/sams/<name>rejects.json (0 tracked) | - | left |
| `grocery/resolve-chips-hyvee.ps1:122` | `$p` | untracked | grocery/out/url-inputs/store-hyvee-nolink-urls.json | - | left |
| `grocery/resolve-ff-boardmatch.ps1:110` | `(Join-Path $dir 'store-ff9-urls.json')` | untracked | grocery/out/url-inputs/store-ff9-urls.json | - | left |
| `grocery/resolve-worklist.ps1:286` | `(Join-Path $OutDir 'url-worklist.json')` | ignored | grocery/out/url-worklist.json | - | left |
| `grocery/sanity-check.ps1:283` | `(Join-Path $OutDir ("guards-"+$week+".json"))` | ignored | grocery/out/guards-<week>.json | - | left |
| `grocery/test-auditors/units-05.ps1:870` | `$ckBase` | temp | fixture dir under %TEMP% | - | left |
| `grocery/test-auditors/units-05.ps1:871` | `$ckLed` | temp | fixture dir under %TEMP% | - | left |
| `grocery/test-auditors/units-09.ps1:52` | `(Join-Path $cvOut 'chain-verdict.json')` | temp | fixture dir under %TEMP% | - | left |
| `grocery/test-guards.ps1:1019` | `$g9F` | harness-restored | live file, bytes restored by RestoreAll | - | left |
| `grocery/test-guards.ps1:1082` | `$g18F` | harness-restored | grocery/out/comparison-*.json | - | left |
| `grocery/test-guards.ps1:1117` | `$g19Aldi` | harness-restored | grocery/out/regular/aldi-regular-*.json | - | left |
| `grocery/test-guards.ps1:606` | `$f` | harness-restored | live file, bytes restored by RestoreAll | - | left |
| `grocery/test-guards.ps1:623` | `$cf` | harness-restored | grocery/commodities.json | - | left |
| `grocery/test-guards.ps1:632` | `$wf` | harness-restored | live file, bytes restored by RestoreAll | - | left |
| `grocery/test-guards.ps1:647` | `$of` | harness-restored | grocery/board-price-overrides.json | - | left |
| `grocery/test-guards.ps1:657` | `$pf` | harness-restored | grocery/product-urls.json | - | left |
| `grocery/test-guards.ps1:667` | `$pf` | harness-restored | grocery/product-urls.json | - | left |
| `grocery/test-guards.ps1:676` | `$sf` | harness-restored | live file, bytes restored by RestoreAll | - | left |
| `grocery/test-guards.ps1:732` | `$exF` | harness-restored | grocery/out/extra-deals-*.json | - | left |
| `grocery/test-guards.ps1:738` | `$cmpF` | harness-restored | grocery/out/comparison-*.json | - | left |
| `grocery/test-guards.ps1:762` | `$hf` | harness-restored | grocery/out/regular/hyvee-regular-*.json | - | left |
| `grocery/test-guards.ps1:783` | `$hf` | harness-restored | grocery/out/regular/hyvee-regular-*.json | - | left |
| `grocery/test-guards.ps1:823` | `$puF2` | harness-restored | grocery/product-urls.json | - | left |
| `grocery/test-guards.ps1:862` | `$bkf` | harness-restored | grocery/out/regular/bakers-regular-*.json | - | left |
| `grocery/test-guards.ps1:882` | `$cmpF2` | harness-restored | grocery/out/comparison-*.json | - | left |
| `grocery/test-guards.ps1:901` | `$of` | harness-restored | grocery/board-price-overrides.json | - | left |
| `grocery/test-guards.ps1:910` | `$of` | harness-restored | grocery/board-price-overrides.json | - | left |
| `grocery/test-guards.ps1:949` | `$pfx` | harness-restored | grocery/product-urls.json | - | left |
| `grocery/test-guards.ps1:996` | `$g6Pick.FullName` | harness-restored | live file, bytes restored by RestoreAll | - | left |
| `grocery/test-guards/ad-line-provenance-8d.ps1:38` | `$g8dCmpF` | harness-restored | grocery/out/comparison-*.json | - | left |
| `grocery/test-guards/ad-line-provenance-8d.ps1:47` | `$g8dCmpF` | harness-restored | grocery/out/comparison-*.json | - | left |
| `grocery/test-guards/ad-line-provenance-8d.ps1:63` | `$g8dCmpF` | harness-restored | grocery/out/comparison-*.json | - | left |
| `grocery/test-guards/ad-line-provenance-8d.ps1:66` | `$g8dCmpF` | harness-restored | grocery/out/comparison-*.json | - | left |
| `grocery/test-guards/ad-line-provenance-8d.ps1:83` | `$g8dCmpF` | harness-restored | grocery/out/comparison-*.json | - | left |
| `grocery/update-history.ps1:373` | `(Join-Path $OutDir ("records-"+$week+".json"))` | ignored | grocery/out/records-<week>.json | - | left |
| `grocery/verify-apply.ps1:129` | `$file` | ignored | grocery/out/verified-<week>.json | - | left |
| `grocery/verify-prep.ps1:37` | `$file` | ignored | grocery/out/verify-input-<week>.json | - | left |
| `grocery/weekly-run-lock.ps1:100` | `$lockPath` | ignored | grocery/out/weekly-run.lock | - | left |
| `lib/ingest-ledger.ps1:150` | `$Path` | ignored | grocery/out/ingest-walmart-batch-<date>.json (only caller) | - | left |
| `meal-prep/engine/golden-test.ps1:190` | `$pIng` | temp | NewTemp perturb dir | - | left |
| `meal-prep/engine/golden-test.ps1:216` | `$ap` | temp | NewTemp frozen dir | - | left |
| `meal-prep/pipeline/audit-price-claims.ps1:211` | `$JsonOut` | caller-path | -JsonOut <path> | - | left |
| `meal-prep/pipeline/build-intake-skeleton.ps1:829` | `$intakePath` | temp | drill under %TEMP% | - | left |
| `meal-prep/pipeline/build-intake-skeleton.ps1:832` | `$snapPath` | temp | drill under %TEMP% | - | left |
| `meal-prep/pipeline/build-run-specs.ps1:409` | `(Join-Path $SpecsDir ($slug + '.json'))` | run-artifact | meal-prep/runs/<run>/specs/<slug>.json (0 ever tracked) | - | left |
| `meal-prep/pipeline/build-run-specs.ps1:412` | `(Join-Path $SpecsDir '_index.json')` | run-artifact | meal-prep/runs/<run>/specs/_index.json (0 ever tracked) | - | left |
| `meal-prep/pipeline/fetch-recipe.ps1:283` | `$metaFile` | ignored | meal-prep/db/page-cache/<key>.meta.json | - | left |
| `meal-prep/pipeline/map-preresolve.ps1:3501` | `$target` | run-artifact | meal-prep/runs/<run>/mapped/<slug>.json (runs last committed 2026-09-23) | - | left |
| `meal-prep/pipeline/map-preresolve.ps1:3694` | `(Join-Path $outDir ("{0}.json" -f $t.slug))` | run-artifact | meal-prep/runs/<run>/mapped-pre/<slug>.json (runs last committed 2026-09-23) | - | left |
| `meal-prep/pipeline/map-preresolve.ps1:963` | `(Join-Path $scratch 'recipes-canon.json')` | temp | mpre-pc scratch under %TEMP% | - | left |
| `meal-prep/pipeline/parse-compute.ps1:609` | `$OutFile` | run-artifact | meal-prep/runs/<run>/recipes-computed.json (0 ever tracked) | - | left |
| `meal-prep/pipeline/parse-compute.ps1:612` | `$OutFile` | run-artifact | meal-prep/runs/<run>/recipes-computed.json (0 ever tracked) | - | left |
| `meal-prep/pipeline/rebid-ingredient.ps1:167` | `$tmpEv` | temp | evidence scratch under %TEMP% | - | left |
| `meal-prep/pipeline/repair-spec-contradictions.ps1:201` | `$f.FullName` | run-artifact | meal-prep/runs/<run>/specs/*.json (0 ever tracked) | - | left |
| `meal-prep/pipeline/retrofit-source-credit.ps1:92` | `$f.FullName` | run-artifact | run specs dir (0 ever tracked) | - | left |
| `meal-prep/pipeline/spec-guards.ps1:428` | `$sf.FullName` | run-artifact | -SpecsDir run specs (0 ever tracked) | - | left |
| `meal-prep/pipeline/sync-prose-from-spec.ps1:147` | `$pf` | run-artifact | <specs>/prose/prose-<slug>.json (0 ever tracked) | - | left |
| `meal-prep/top5-weekly.ps1:72` | `(Join-Path $gout 'recipe-costs.json')` | ignored | grocery/out/recipe-costs.json | - | left |
