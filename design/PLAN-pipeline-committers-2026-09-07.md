# Plan - move the committer from the entry point to the work

Written 2026-09-07 before building, because this puts three more scripts in the business of committing
to main on a schedule. Brad ruled the full scope: `check-ad-cycles`, `nightly` and `harvest-crawl` all
commit the paths they own.

## The finding this comes from

`capture-run.ps1` is the **only** committer in the estate. `check-ad-cycles.ps1` does all the pricing
work and commits nothing - it is called *by* capture-run, which commits afterwards. So the commit is
bound to the entry point rather than to the work, and any other route into the same pipeline leaves its
output uncommitted:

| Route | Commits? | Yesterday's evidence |
|---|---|---|
| the three TC Grocery tasks -> `capture-run` | yes | 07:02 and 08:33 |
| triage running `check-ad-cycles` directly | **no** | the 09:51 recost, the 11:55 board correction, ~141 files |
| `nightly.ps1` (TC Graph Nightly Matching) | **no** | 21:30-21:32 graph state |
| `harvest-crawl.ps1` (TC Recipe Harvest Crawl) | **no** | 18:06-20:21 pool and harvest state |

The work ran four times yesterday and the committer ran twice.

## What this plan will NOT do, and why

**No sweeper.** `ops/audit-git-sweepers.ps1` forbids `git add -A` without a `--` pathspec, after four
incidents of one shape - the most recent on **2026-09-05**, when `push-data.ps1` put 325 files on main,
192 of them `.ps1` **mid-edit**, 27 of which threw at startup, and left them there for 59 minutes. A
sweeper running at 21:30 yesterday would have committed the sibling session's half-finished agent files
and my in-progress gates. "Never uncommitted again" implemented that way is worse than the problem.

**No refactor of `capture-run`'s commit stage.** It is the most safety-critical code here: a private
temp index so the bot commits exactly its own add set rather than whatever a session left staged
(2026-08-25, `0c47012c`), an explicit pathspec, a commit-size gate, and rebase/push handling. It works
and it carries the scar tissue of four incidents. The new committers are **additive** and reuse the
pattern; that file is not touched.

## Design

### `lib/pipeline-commit.ps1` - one implementation, three callers

- `Get-PipelinePaths -Kind pricing|graph|harvest` - the explicit path list each owner may stage.
- `Assert-NoSourcePaths $paths` - **the load-bearing safety invariant.** A data committer must be
  structurally incapable of staging source. Any path that could match `*.ps1`, `*.py`, `*.md`,
  `.claude/**` or `ops/**` is a hard refusal, not a warning. This is what makes an unattended committer
  safe in a tree two sessions are editing, and it is the direct answer to 2026-09-05.
- `Invoke-PipelineCommit -Repo -Paths -Message -Name [-Push]` - seeds a private index from HEAD, stages
  only the given paths, refuses on the source assertion, commits, and attempts one push.

### Push policy: try once, never block

Three new committers plus the existing one can race. Each attempts a single push; on failure it leaves
the commit local and says so, and the next `capture-run` pushes it. A commit that exists locally is
already the whole of what "not uncommitted" means, and a retry loop between four schedulers is a worse
failure than a late push. The `~07:00` bot's autostash rebase only rebases when `origin/main` actually
moved, and that behaviour is unchanged.

### Double-commit avoidance

`capture-run` calls `check-ad-cycles -NoPull`; it will now also pass **`-NoCommit`**. So the daily path
commits exactly once, in the stage that does it today, and `check-ad-cycles` commits only when someone
ran it directly - which is the triage case that went uncommitted yesterday.

## Order, and the stop condition

1. `lib/pipeline-commit.ps1` with its self-test, including the must-fire that a source path is refused.
2. `harvest-crawl` and `nightly` - lowest risk, they own disjoint paths nothing else writes.
3. `check-ad-cycles -NoCommit`, and `capture-run` passing it. Highest risk, done last and alone.

**Stop and report rather than push through** if the source-path assertion fires on any real path list,
or if a self-test cannot distinguish a data path from a source one. A committer that cannot prove it
will not stage source does not ship.

## What this does not solve

A session editing data files by hand still produces uncommitted work with no owner. That is correct -
it is a human's to commit, and a machine that hoovered it up is the 2026-09-05 incident.
