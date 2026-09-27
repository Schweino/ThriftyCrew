# PLAN: split the four largest PowerShell files into pieces small enough to rewrite whole

Status: PROPOSED, awaiting Brad's rulings D1-D6. Nothing built.
Date: 2026-09-27. Scope: `grocery\test-auditors.ps1` (8,027 lines), `ops\push-main.ps1` (4,962),
`grocery\check-ad-cycles.ps1` (4,577), `grocery\compare-deals.ps1` (3,742). Behaviour must not change.
Drafted by a read-only planning agent; the file readings below are its own and are inputs, not verified facts.

## Knowledge consulted
- `~/.claude/CLAUDE.md` "Structure is context": keep files small enough to rewrite whole.
- rules:grocery.md (compare-deals is lifted; a lifted `$script:` constant does not travel).
- rules:ops-and-gates.md og-35 (self-test discoverability) and og-45 (gate-input keys).
- CLAUDE.md 2026-09-27: new machinery must pay for itself.

## 0. Rules for every step
1. **MOVE, never edit.** Cut text, paste it byte-identical into the new file, add the one dot-source line. No renames or tidying in the same commit.
2. **Equivalence is proven by function-body hashes.** Parse before and after with the PowerShell parser, hash every function body; the sets must be equal, only the file differs.
3. **Dot-source only, at the exact spot the code was**, never `&` or `Import-Module`, so `$script:` variables, free variables and `Log`/`Say` redefinitions resolve as before.
4. **New lib files carry no `param()` block.**
5. **One step, one commit, landed through push-main.** No step leaves a caller pointing at moved text.
6. **Gate inputs follow the code (og-45)**: the new file joins the host's `# gate-inputs:` line; `lib\gate-input-key.ps1 -VerifyDeclared` passes for host and new file.
7. **Self-tests stay discoverable (og-35)**: after each step `ops\audit-mustfire-census.ps1` and `ops\audit-fixture-inputs.ps1` show the same must-fire count per file, or moved one-for-one. Any drop is a failure.

## 1. Ranking (value vs risk)
| Rank | File | Value | Risk | Why |
|---|---|---|---|---|
| 1 | test-auditors.ps1 | Highest (biggest, most edited) | Lowest | A test harness with no production caller; already 168 named `Use-Unit` seams; verdict is a pure function. |
| 2 | push-main.ps1 | High | Medium (self-test only) / High (core) | The `if ($SelfTest)` block is lines 2575-~4950 (~2,400); moving it touches no production path. Leave `Invoke-TcPushMain` (1909-2573) alone for now. |
| 3 | compare-deals.ps1 | High | High | Its text is lifted by other scripts; self-test (572-~2350) is interleaved with dot-sources. |
| 4 | check-ad-cycles.ps1 | Medium | Highest | Mostly flat script scope; one `if` holds the whole downstream chain (1058-~3780); its self-test parses its OWN AST, so moving code blinds it. |

**Recommendation:** test-auditors first, then push-main's self-test only (pause, review), then compare-deals, and check-ad-cycles last and only after D4.

## 2. grocery\test-auditors.ps1
**Today:** 1-200 bootstrap and helpers (`PSChild`, `Register-Fx`/`Sweep-FxPaths`, `Ok/Bad/Skip/Hygiene/Live`, `Use-Unit`, `Get-AuditorsVerdict`, `RunPS`/`RunPSMany`, `Start-Early`/`Get-Early`, early fan-outs start at 358); `RunTriage` ~580; reads compare-deals source at 740 and 799; sandbox helpers ~1085 (`NewFxDir`, `RunPSAt`, `Get-FxLibGaps`, `_WfpSeed`); then ~168 `Use-Unit` blocks, source-shape testers near 2644-2800, local `Log`/`Get-Date` overrides inside units at 2911 and 3403, compare-deals source reads at 3303 and 6273. Run by run-gates and weekly by check-ad-cycles (`Test-CadenceDue -InputGlobs 'grocery/*.ps1', ...`); push-main keeps it warm and reads its scope (`Get-TcHookTestAuditorsScope`, `Get-TcTaKeyMoved`).

**Target** (flat siblings per D2, all dot-sourced from a slim entry):
| Name | File | ~Lines |
|---|---|---|
| auditors harness | `test-auditors-harness.ps1` | 350 |
| auditors sandbox kit | `test-auditors-sandbox.ps1` | 250 |
| compare-deals source checks | `test-auditors-units-compare-deals.ps1` | 500-700 |
| chain/cycle, pricing/board, publish/site, ops/hygiene, self-test roll-call units | one file each | ~900 each, split again past 1,000 |
| entry | `test-auditors.ps1` | ~250 |
Final grouping comes from a read-only count of `Use-Unit` ids per subject at the start of the work.

**Order:** harness, sandbox kit, then one unit group per commit starting with the self-test roll-call.
**Proof:** function hashes; a golden run before and after on one tree, normalised for timings and temp paths, with identical PASS/FAIL/SKIP/HYGIENE/LIVE lines per unit, counts and exit code; identical `$script:UnitsRan`; a single-unit run still selects a moved unit.
**Traps:**
- It counts things in its own text (comment at 1552: "46 -SelfTest call sites in this file"). Find every scanner of `test-auditors.ps1` (itself, run-gates, `Get-TcHookTestAuditorsScope`, `Get-TcTaKeyMoved`, audit-mustfire-census) and point it at the entry plus the new files in the same commit.
- Cache and cadence keys: push-main's reuse (`rg_reused`, `Test-TcTaReused`) and check-ad-cycles' `-InputGlobs` must see the new files. `grocery/*.ps1` does not match a subdirectory, hence D2.
- Nested `function Log` (2911) and `function Get-Date` (3403) live inside a unit's scriptblock; dot-sourcing keeps that scope. Never wrap a unit file in a function.
- All `Start-Early` calls stay in the entry, before any `Get-Early`.
- `$script:FxPaths` is shared state: fine under dot-sourcing, broken under `&`.

## 3. ops\push-main.ps1
**Today:** 1-215 help and gate-inputs (183-184); 221-440 git/plan/`Say`/warm gate/seeding/warm test-auditors; 442-606 rehearsal; 608-682 checkout guard; 684-930 sync to remote and default legs; 933-1297 reject classification and readings; 1299-1466 subjects and SHA readings; 1468-1607 backlog and re-read preflight; 1609-1727 prepare and detached process; 1729-1820 chain-queue conflict; 1822-1908 via-worktree and re-exec; 1909-2573 `Invoke-TcPushMain`; 2575-~4950 `if ($SelfTest)`; last 12 lines the dispatcher.

**Target:**
| Name | File | ~Lines |
|---|---|---|
| push-main self-test | `ops\push-main-selftest-sync.ps1`, `ops\push-main-selftest-land.ps1` (D1 shape) | ~1,200 each |
| rehearsal | `lib\push-rehearsal.ps1` | 170 |
| checkout guard | `lib\push-checkout-guard.ps1` | 75 |
| sync to remote | `lib\push-sync.ps1` | 250 |
| push readings | `lib\push-readings.ps1` | 530 |
| push preflight | `lib\push-preflight.ps1` | 260 |
| chain-queue conflict | `lib\push-stack-conflict.ps1` | 95 |
| push-main itself | params, dot-sources, `Invoke-TcPushMain`, re-exec, dispatcher | ~1,000 |

**Order:** self-test (two halves); pause and review; readings (no git side effects); then guard, rehearsal, sync, preflight. `Invoke-TcPushMain` stays.
**Proof:** function hashes; `push-main.ps1 -SelfTest` same case count and same MUST FIRE / MUST NOT FIRE / CLEAN TWIN lines and exit; `-DryRun` on a scratch clone prints the same plan; the first real landing of each split commit is the live proof (push-ledger row normal).
**Traps:**
- **Half-landing and re-exec.** The old push-main lands the split commit, then re-execs the new copy from the throwaway worktree, which dot-sources the new libs relative to that worktree. Safe only if lib and host land in ONE commit; never "add lib" and "remove from host" separately. Rehearse first: `-SelfTest`, then `-DryRun` with `TC_PUSH_MAIN_REEXEC=1` from a scratch worktree. Keep the previous push-main blob in the commit message. The existing fallback (re-exec returns `$null`, the running copy goes on) must stay.
- Seeding: confirm `ops\seed-worktree.ps1` / `lib\seed-hint.ps1` have no per-file allow-list that would miss new libs.
- Self-test discoverability: the moved file must carry the gate-inputs line and be found by `Get-SelfTestBlock`; run-gates still calls `push-main.ps1 -SelfTest`, whose body becomes a dot-source and exit (D1).
- `Say` is defined in the host and captured by fixtures: dot-source the self-test after it.
- `$script:TcPmReexecExtra` (set 1907, read by the dispatcher) stays in the host.
- **`Get-TcScriptBlob`** hashes push-main's own blob. If that is the "has push-main changed since this run started" test, it must hash host AND libs, or a lib-only change would let a stale copy land a push. Settle before step 3 (D3).

## 4. grocery\compare-deals.ps1
**Today:** 1-110 params and ~10 dot-sources; 113-570 pure functions (`Get-ProdKey`, `Test-Band`, `Get-FirstRefusal`, `Select-StoreWinner`, `Get-RowSrcDate`, `Add-TcNamelessRow`, `Resolve-NativeUnitPrice`, ...) with interleaved dot-sources; 572-~2350 `if ($SelfTest)`; 2353-2880 row identity, normalisation, ad-match, rollback TTL; ~2882 `$GLOBAL_EXCLUDE = Get-TcGlobalExclude`, `Get-MatchTexts`, `Match-Category`, up to the `# ---- -Explain` banner; then match-lib, known-wrong, price table, write.

**Lifter census** (`ops\count-source-lifters.ps1 -Script compare-deals.ps1`, run 2026-09-27): NAMES 63 (57 outside out), READS 8 (5 outside out), EXECUTES 1.
| Reader | Takes | Split must keep |
|---|---|---|
| `grocery\test-match-lib.ps1:176-210` (EXECUTES) | text from the `$GLOBAL_EXCLUDE = Get-TcGlobalExclude` anchor to the `-Explain` banner, run via `[scriptblock]::Create` | anchors, region and column-0 layout byte-identical in the host; nothing in that region becomes a dot-source (`$PSScriptRoot` is empty there) |
| `test-auditors.ps1:740` | source-shape assertions | stays in host, or repoint in the same commit |
| `test-auditors.ps1:799` | "must NOT divide" fixture inside the self-test | repoint if the self-test moves |
| `test-auditors.ps1:3303` | encoding check | cover every new file |
| `test-auditors.ps1:6273` | source-shape | same |
| `grocery\test-precedence-ladders.ps1:232` | reads a sandbox copy | sandbox copy list must include each new lib |
The census is UNSOUND, so before step 1 also grep `compare-deals` with `IndexOf|Substring|ReadAllText|-Raw|ParseFile` across grocery, ops, lib, and review the 57 NAMES hits by eye.

**Target:**
| Name | File | ~Lines |
|---|---|---|
| compare-deals refusals | `grocery\compare-refusal-lib.ps1` (113-310) | 200 |
| compare-deals ranking | `grocery\compare-rank-lib.ps1` | 250 |
| compare-deals self-test | `grocery\compare-deals-selftest-*.ps1`, three by fixture family | ~600 each |
| row identity | `grocery\compare-identity-lib.ps1` (2353-~2730) | 380 |
| compare-deals itself, lifted region untouched | host | ~1,000 |

**Order:** refusals and ranking libs; identity lib; self-test last (four readers care about its text).
**Proof:** function hashes; `-SelfTest` same lines, pass count and exit; a golden run on a frozen copy of `grocery\out` in scratch with byte-identical `comparison-*.json` and identity/link sidecars, same post-steps both times (never revert-to-isolate; diff); `test-match-lib.ps1` green and not BLIND; `test-precedence-ladders.ps1` green; test-auditors `$cd*` units green.
**Traps:** the lifted region; lifted `$script:` constants do not travel; the self-test sits mid-file and depends on dot-sources before 572 but not those after (match-lib loads after it), so its dot-source goes at 572 exactly; the local `Read-JsonFile` at 113 shadows `lib\json-io` and stays.

## 5. grocery\check-ad-cycles.ps1
**Today:** 55-63 params; 63-~328 the self-test runs FIRST and walks its own AST (checks ship calls sit under `-NoCommit`/`-NoPublish`, the `$ShipOnly` ifs, first `top5-weekly` inspect, `Out-Null` pipelines; fakes `Log`/`Send-Alert` at 256); 330-460 bootstrap and 10 dot-sources; 461-712 cadence gate, bounded children, guards gate; 747-1057 server pull and schedule rebuild; 1058-~3780 one `if` with the whole downstream chain (flat scope, nested local functions at 1899 and 2371); 3780-4577 ~20 independent DAILY/WEEKLY try-blocks.

**Target:**
| Name | File | ~Lines |
|---|---|---|
| cadence and bounded-child lib | `grocery\cycle-runner-lib.ps1` (461-712) | 250 |
| watchers tail | `grocery\cycle-watchers.ps1` (3979-4577) | 600 |
| post-publish checks | `grocery\cycle-postpublish.ps1` (3780-3978) | 200 |
| server-pull stage | `grocery\cycle-pull.ps1` (747-1057) | 310 |
| downstream chain | stage files at its `# ----` banners (~5 x 550) | 2,700 |
| host | params, self-test, bootstrap, stage dot-sources, verdict | ~700 |

**Order, only after D4:** runner lib, watchers tail, post-publish checks; stop and review before the downstream chain.
**Proof:** function hashes; `-SelfTest` same MUST FIRE lines and count; golden `-NoCommit -NoPublish` run on a frozen `grocery\out` with identical log lines, chain-verdict document and written files after timestamp normalisation; test-auditors cac units (`Test-CacInspectGating` ~2785 and others) green.
**Traps:** the self-AST checks go blind on moved code and a zero-match check can pass vacuously, so the self-test must first parse host plus every stage file and assert a minimum count per needle, a reviewed commit of its own (D4); test-auditors reads this file as text, repoint in the same commit; stages dot-sourced inside the `if` keep flat scope, a function wrapper would lose `$hardFail`, `$script:DownstreamRan` and dozens more; `Log` is defined twice (fixture 256, real 365), stages load after 365; cadence globs must cover new files.

## 6. Every extraction, same steps
1. Baseline: self-test output, golden output, function hash table (scratchpad).
2. Cut and paste, add dot-source, update gate-inputs, repoint text readers.
3. Function hash diff: empty apart from the file column.
4. `-SelfTest` diff against baseline.
5. Golden output diff: byte-identical.
6. `audit-mustfire-census`, `audit-fixture-inputs`, `gate-input-key -VerifyDeclared` on host and new files, lifter census.
7. One commit through push-main; push-main steps get the scratch re-exec rehearsal first.

Steps 3 and 5 are worth one small script, `ops\prove-split.ps1`, used ~20 times (D5). Cost: one self-tested script; it replaces a hand procedure repeated per extraction.

## Decisions for Brad
- **D1. Shape of a moved self-test.** (a) host keeps `if ($SelfTest) { . .\x-selftest.ps1; exit ... }` and the new file declares its gate-inputs, which needs `Get-SelfTestBlock` (`lib\selftest-lib.ps1`) to follow the dot-source; or (b) the existing `$__xxSelfTest` dot-sourced form. Recommended: (a).
- **D2. Subdirectory or flat siblings?** A subdirectory falls outside the `grocery/*.ps1` cadence and cache globs. Recommended: flat.
- **D3. push-main: move only the self-test and pure readings, keep the core in the host?** Recommended: yes. And make `Get-TcScriptBlob` hash host plus libs, as its own commit, before any production code leaves push-main?
- **D4. check-ad-cycles: approve the self-test change (AST over all stage files, minimum match counts) first,** or split only its runner lib and watchers tail?
- **D5. Build `ops\prove-split.ps1`, or run the checks by hand each time?**
- **D6. Keep compare-deals' lifted region frozen in the host for good?** Recommended: yes (~130 lines, not worth changing how the lift works).

## Open before starting (not read by the planner)
- `Get-TcScriptBlob` (what it hashes) and `Get-TcHookTestAuditorsScope` (what it scans): the D3 and test-auditors reader traps depend on them.
- The 57 NAMES hits for compare-deals, reviewed by eye.
- `ops\count-source-lifters.ps1` ran only under `-ExecutionPolicy Bypass`; the bare `-File` form was blocked by execution policy.
