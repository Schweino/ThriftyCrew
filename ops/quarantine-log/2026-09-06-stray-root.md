# Quarantine: four stray artifacts at the repo root

2026-09-06, backlog I2. Moved, not deleted. **This file is the inverse of the move** - it is the only
record of what was where, so a restore is a second forward action rather than a reconstruction from a
conversation that will not survive the next session.

**Where they went:** `C:\Codex\_quarantine\2026-09-06-thriftycrew-stray-root\`, names unchanged.
Note that path is outside any git repo, so it has no undo of its own. Do not clear it without reading
the "writer" column below and confirming each one is closed.

**Why they were invisible.** `.gitignore` line 3 is `/*`: the repo root is ignored by default and
allow-listed back one entry at a time. Debris landing there is invisible to `git status`, to every
audit and to the gate. The two the backlog named had sat for days; a third and fourth turned up only
because `ops/audit-stray-root-artifacts.ps1` was written to enumerate the root structurally.

| Entry | Size | Last written | Writer |
|---|---|---|---|
| `3 cups sliced, for topping` | 7,094,631 bytes | 2026-09-03 16:46 | **UNKNOWN** |
| `CodexThriftyCrewgroceryoutcaptures_sink` | empty dir | 2026-08-28 09:04 | **UNKNOWN** |
| `R` (holding `qa/s1.json`, `s2.json`, `s3.json`) | 3 files, 77 bytes each | 2026-08-25 20:22 | **CLOSED - see below** |
| `probe-candidates.tmp.json` | 2,358 bytes | 2026-08-27 09:45 | **UNKNOWN**, unreferenced |

## `R/` - writer found, and it was already fixed

Closed without further work, because the repo already documents it. `hunt_daemon_selftest.py`'s
`daemon()` helper defaulted `run_dir` to the bare string `"R"`, and `hunt-daemon.py:6611`
(`os.path.join(self.run_dir, "qa", "%s.json" % slug)`) then wrote `R\qa\<slug>.json` **relative to the
current working directory**. Run from a repo root that lands as `R\` at the root, which the `/*` rule
ignores, so nothing ever saw it. The three files carry slugs `s1`, `s2`, `s3` and the exact
`slug/verdict/owner/findings` shape of `hunt_lib.QA`, which is the fixture's own schema.

The defect was measured and fixed 2026-08-26; the comment above `scratch_dir()` in
`hunt_daemon_selftest.py` records it, and the helper now reads `run_dir or scratch_dir()`. **These
files are dated 2026-08-25, one day before the fix, so they are pre-fix residue and not evidence of a
live bug.** Related: memory `test-suites-leak-temp-dirs`.

## The other three - still open

`3 cups sliced, for topping` is 7 MB of tab-separated scaler output, four columns
(`slug / servings / base amount / scaled amount`), the first rows all
`fajita-chicken-rice-bowl`. The **filename is a base amount from the third column**, so a variable
holding a measurement string reached the place a path belonged. A static search across `meal-prep/`
and `grocery/` found no script emitting that four-column shape and no redirect to an unquoted
variable, so the writer is not identified. `CodexThriftyCrewgroceryoutcaptures_sink` is
`C:\Codex\ThriftyCrew\grocery\out\captures_sink` with every separator eaten - a path joined by
concatenation - and is empty, so it carries no evidence of its own beyond the name.

**If either shape reappears at the root, the gate now catches it in the act rather than days later**,
which is the difference that matters: the writer is findable while the run that made it is still in
reach. That is what `ops/audit-stray-root-artifacts.ps1` exists for.
