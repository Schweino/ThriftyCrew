# Native stderr under EAP=Stop, repo-wide: every site ruled (2026-09-11)

**The bug class.** Under Windows PowerShell 5.1 with `$ErrorActionPreference = 'Stop'`, redirecting a native
child's stderr makes the child's first stderr line a terminating `NativeCommandError` in the parent.
`grocery\native-lib.ps1` has the history. Measured again on this box on 2026-09-11, with a child that writes one
stderr line and one stdout line: `2>&1`, `2>$null`, `*>&1`, `*>$null`, `> log 2>$null`, `2> file` and a bare
`git ... 2>&1` all killed the caller (rc=1, no completion marker). An unredirected call survived. A `try { } catch { }`
around the redirect survived and **lost the child's stdout**, so a catch is not a guard. `grocery\test-native-stderr-eap.ps1`
CASE 3a keeps that measurement live.

**How it was found.** `meal-prep\pipeline\wave-preaudit.ps1`'s `-SelfTest` drill died mid-suite with no FAIL line and
no summary. The watcher's CASE 5 derived its targets from "sets EAP=Stop", but it walked only `grocery\`.

## Harness and commit

- Base: origin/main `0a681beb0`. Line numbers below are at that commit.
- **Regex count.** The old CASE 5 pattern, quote rule, Start-Job skip and 8-line guard window, with the walk widened
  to the repo root (excluding `\archive\`, `\.claude\`, `\.git\`). Run from a scratch copy.
  Result: 572 .ps1 walked, 473 set 'Stop', **67 unguarded hits**.
  The brief measured 65 at `d2ee101cb` plus the unmerged wave-preaudit fix.
- **AST prototype count.** A scratch script that became the shipped watcher's rule. It covered commands by native name
  plus variables named like a native, and walked `\out\`.
  Result: 614 walked, 476 'Stop', **71 unguarded sites**.
- **Final watcher, at this document's commit.** `\out\` excluded, and the watcher excludes itself.
  Result: 576 walked, 480 'Stop', 57 guarded, **2 unguarded**. Both are `meal-prep\pipeline\wave-preaudit.ps1`,
  in the named baseline `grocery\native-stderr-eap-baseline.json`.

**The two counts do not agree, and neither is a superset.**
- Regex 67 = 45 real sites the AST also finds, plus 22 that are not unguarded code.
- AST 71 = those 45, plus 26 the regex could not see. One of the 26 is `grocery\out\staples300\process-agents300.ps1:30`,
  one-off debris now outside the walk, so 70 are in scope.
- 70 in scope = 68 fixed on this branch + 2 left to branch `claude/wave-preaudit-drill-stderr`, where commit `f7161430d`
  already fixes them. Merging that branch lowers the baseline: a plain run reports the fall, and `-Tighten` records it.

## Not real: 22 regex hits left unchanged

| Site (at 0a681beb0) | Why it is not a live defect |
|---|---|
| `ops\prepush-test-auditors.ps1` :251 :384 :446 :1081 :1188 :1189 :1211 :1247 | A script-scope `$ErrorActionPreference = 'Continue'` at :163 precedes every one of them. The 8-line window could not see it. |
| `ops\audit-git-fixture-env.ps1` :145-:153 :169 :171 :175 | Inside `if ($SelfTest)`, whose :78 sets 'Continue' for the whole block. |
| `ops\audit-git-fixture-env.ps1` :160 :161 | Text inside a here-string: the body of a child script written to disk, not code in this file. |
| `ops\brain-digest.ps1:54` | Prose in a `<# #>` help block. The call it describes, :63, is guarded at :62. |

## Real: 68 fixed

- **Shape 1:** `Invoke-NativeScript` / `Invoke-Native`, reading `.ExitCode` and `.Lines`.
- **Shape 2:** `$prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'` as its own statement, then
  `try { call } finally { restore }`. An existing catch is kept.
- **Starred** sites were invisible to the old regex.

| File | Sites | Shape | What a stderr line did before |
|---|---|---|---|
| `ops\verify-commodities-gate.ps1` | :160 | 2 | Threw into a catch. The staged set read **empty**, so a matching-rule change passed as "not applicable". |
| `ops\verify-commodities-gate.ps1` | :136 :137 :138 :141 | 2 | Self-test fixture git calls died on a git hint. |
| `ops\run-gates.ps1` | :694 :696 | 2 | Threw into a catch, and the red-gate event recorded an empty commit and branch. |
| `ops\audit-gate-followthrough.ps1` | :75 :78 | 2 | Threw into a catch, and the gate read as having **no follow-up commits**. |
| `ops\consistency-oracle.ps1` | :251 :261 | 2 | git's "does not exist" threw before the exit-code check that expects it. |
| `ops\consistency-oracle.ps1` | :277 | 2 | One stderr line from an arm lost both arms' verdicts. |
| `meal-prep\pipeline\wave-publish.ps1` | :617 (Invoke-Gate), :721\*, :822, :846\*, :853, :942, :955, :1100, :1102 | 1 | **Publish path.** Died mid-stage; :721 and :846 are backtick-continued. |
| `meal-prep\pipeline\wave-publish.ps1` | :934 | 2 | Died mid-stage. |
| `meal-prep\rotate-free-dinners.ps1` | :248\* :259\* | 2 | `*>&1` inside a try. A child that warned but exited 0 read as a failed resync. |
| `meal-prep\pipeline\run-scaler-pricing-test.ps1` | :86\* | 1 | `& $NodeExe`. |
| `meal-prep\pipeline\hunt-run.ps1` | :607 (live), :987 :999 :1007 :1011 :1021 :1047 :1094 :1121 :1173 :1201 :1240 (drills) | 1 | Suite or queue read died. |
| `meal-prep\pipeline\map-preresolve.ps1` | :331 | 1 | Died. |
| `meal-prep\pipeline\map-preresolve.ps1` | :373 (stdin piped to python) | 2 | The catch reported "the splitter would not run" and **discarded its JSON**. |
| `meal-prep\pipeline\build-intake-skeleton.ps1` | :659 | 1 | Died. |
| `meal-prep\pipeline\audit-lane-shape.ps1` | :504 | 1 | Died. |
| `meal-prep\pipeline\sync-prose-from-spec.ps1` | :235 :240 | 2 | Died. |
| `meal-prep\pipeline\feed-freshness.ps1` | :353 | 2 | Died. The file is dot-sourced elsewhere, so it adds no dependency. |
| `meal-prep\test-scale-hardening.ps1` | :82 :88 :93 | 1 | Died. |
| `grocery\apply-coverage-batch.ps1` | :108\* :138\* :143\* :289\* :292\* :294\* :295\* :330\* :332\* :333\* :341\* :342\* :343\* :364\* | 1, through a local `Invoke-BatchChild` | `*>&1 \| Out-Null`. A throw **between a rule edit and its Revert** left the edit applied. |
| `grocery\check-ad-cycles.ps1` | :876\* | 1 | Threw into a catch, so the "BOARD AND FEED ON DIFFERENT WEEKS" alert **could not fire**. Hidden from the regex by a Start-Job mention above it. |
| `grocery\bakers-daily-scan.ps1` | :74\* | 2 | Bare `git pull ... 2>&1` in a daily task. git writes routine progress to stderr, so the pull threw into its catch. |
| `grocery\test-auditors.ps1` | :1955\* :2787\* | 1 | Died. Also hidden by a Start-Job mention. |
| `check-uncommitted-source.ps1` | :126\* | 2 | Bare `git init` in its self-test. |
| `graph\pipeline\nightly.ps1` | :274 | 'Continue' as the function's first statement | Threw into a catch and VRAM read unknown. A `finally` here broke nightly's own self-test, which finds its teardown by the first `finally`, so the preference is scoped to the function instead. |
| `tools\local-llm\install.ps1` | :46 | 2 | Threw into a catch and the installer reported "nvidia-smi not found". |

## How each fix was verified

"Harness" means a scratch child that writes one stderr line and one stdout line and exits 3, run through the new
statement shape under 'Stop'. Each harness showed the new shape surviving, reading 3 and keeping the stdout line, and
the old shape dying, so it is not vacuous.

**Self-tests run before and after the edit**
- **Same exit code and identical case lines:** `verify-commodities-gate`, `audit-gate-followthrough`,
  `consistency-oracle` (the "before" run was the origin/main copy in a temp mirror), `wave-publish`,
  `rotate-free-dinners`, `hunt-run`, `map-preresolve`, `build-intake-skeleton`, `audit-lane-shape`,
  `sync-prose-from-spec`, `feed-freshness`, `check-uncommitted-source` and `nightly`.
- `run-scaler-pricing-test` has no self-test; its own hermetic jsdom run was compared instead.

**Harness only (live paths nothing hermetic reaches)**
- `wave-publish`'s P5 to E6 stages and `rotate-free-dinners`, which publish.
- `apply-coverage-batch`, which edits rules and rebuilds the board.
- `check-ad-cycles`, the whole daily chain.
- `bakers-daily-scan`, `install.ps1`.
- `test-scale-hardening`, whose checks use the network and rewrite tracked files.
- `hunt-run:607` and the two `test-auditors` sites.

No real git or nvidia-smi stderr was produced for those sites.

**Behaviour that changed on purpose**
- In `rotate-free-dinners`, a child that writes to stderr and exits 0 is now a success.
- In `map-preresolve`, the splitter's JSON is kept when python also warns.

## The watcher, and what its clean report does not prove

`grocery\test-native-stderr-eap.ps1` now reads the PowerShell AST of every `.ps1` below the repo root that sets 'Stop'.
It runs in `run-gates` and is ratcheted by named site. The old regex was blind in these ways, each with a live site
behind it:
- backtick continuations;
- `*>&1`;
- bare `git` with no `&`;
- everything after any line mentioning Start-Job.

It also accused comments, here-strings, and block-wide or script-wide 'Continue'.

Its self-proof:
- 15 known-bad shapes and 14 legal shapes;
- a MUST FIRE for a site in `ops\` and in `meal-prep\pipeline\`, from a worktree-shaped fixture root;
- ratchet cases by name.

A mutation probe was run against it when this document was written; the commit message records the result.

**Known gaps (UNSOUND by construction)**
- **Variable commands.** A native invoked through a variable is seen only when the variable is named like one
  (`$py`, `$NodeExe`, `$PSEXE`). `ops\run-gates.ps1:417` `& $cand --version 2>&1` is not seen. It sits in a catch, and a
  miss there is loud ("no Python 3 interpreter found"), so it was left.
- **Lexical reading.** The preference is read lexically. A function inherits its caller's preference at run time,
  which is not followed.
- **Libraries.** A library that never sets 'Stop' is not scanned, though its callers run it under 'Stop'.
- **Conditional guards.** A preference set inside a branch or a try before the call reads as `conditional`, which is
  never a guard. This is a conservative false alarm when the branch always runs.

## Found in passing, not fixed here

- **Fixed temp name.** `meal-prep\pipeline\feed-freshness.ps1`'s self-test writes the fixed name
  `%TEMP%\ff-clobber-probe.ps1`. This is the concurrent-run clobber shape in `.claude\rules\ops-and-gates.md`.
