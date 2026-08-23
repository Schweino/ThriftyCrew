# PLAN — storage hygiene: delete what we don't need, and make "clean" the default

**Status: PROPOSED, 2026-08-23. Plan only — for Opus to implement. Nothing here has been changed.**
Brad's question: *what's the smartest way to delete what we don't need now, and ensure we stay clean
going forward?* The answer has a shape: one real problem (a 191 MB credential in git history), one
structural cause (the daily commit **sweeps** a directory instead of **allowlisting** it), one thing
we are losing that we should keep, and a short list of things that look like waste and are not.

Every number below was measured on 2026-08-23. The working tree is **27 GB**; `.git` is **395 MB**.

---

## 0. The finding that reframes everything

| | |
|---|---|
| `.git` pack | ~380 MB |
| of which `grocery/out/browser-profiles` | **191 MB — 50%** |
| of which `grocery/out/regular` (173 daily snapshots, 399 MB on disk) | **30 MB** |

The grocery data — the thing that *looks* like the storage problem — packs to 30 MB because git
deltas near-identical daily snapshots superbly. **The repo's storage problem is two days of a Chrome
profile directory that a `git add -A -- grocery/out` swept in.** Everything in this plan follows from
that: the profile has to leave history (§2, Brad's decision), and the sweep has to become a gate (§3)
so the *next* new subdirectory under `out/` does not do the same thing.

---

## 1. Delete now — safe, no decision needed, Opus can do it unattended

### 1.1 Two `.pyc` files are tracked, and ten `__pycache__` dirs are one `git add -A` from joining them

```
meal-prep/pipeline/__pycache__/coverage_check.cpython-312.pyc    <- tracked
meal-prep/pipeline/__pycache__/local_extract.cpython-312.pyc     <- tracked
```

`.gitignore:90` covers `/sidecar/**/__pycache__/` only. Ten more `__pycache__` directories exist
outside `sidecar/` (`graph/agentic`, `graph/eval`, `graph/gold`, `graph/import`, `graph/learning`,
`grocery/`, …), unignored.

**Do:** replace the sidecar-only rule with a repo-wide `__pycache__/` and `*.pyc`; `git rm --cached`
the two tracked files. Compiled bytecode is regenerated on every import and is never source.

### 1.2 The two `LOCKED` log sidecars — do nothing

`grocery/ad-cycle-log.LOCKED-2026-08-22.txt` (214 KB) and `-23` (52 KB) are untracked and
unignored. They are **not waste**: `check-ad-cycles`' SIDECAR-RECOVERY folds any *prior* day's
sidecar back into the primary log on the next run that can write it, then deletes the sidecar. The
08-22 one will fold on the next clean run; today's folds tomorrow. **Leave them.** (They are
unignored on purpose — an ignored sidecar would be a log nobody could find.)

### 1.3 `grocery/out/archive` — 91 MB, 57 files, read by nothing — **but it is a policy, not litter**

`prune-out.ps1:46`: *"DIRECTORY families are ARCHIVED (moved under out\archive\), never deleted."*
Its own header says why: *"disk is cheaper than a blinded guard."* The directory is ignored by git,
costs 91 MB of a 27 GB tree, and the only other reference in the estate is `test-precedence-ladders`
**excluding** it. Deleting it by hand contradicts a stated design rule to save 0.3% of disk.

**Do:** not `rm`. Give `out/archive` an age-out of its own in `prune-out.ps1` — the same `days / min`
shape every other family has (suggest `days = 90; min = 5`, matching `QuarterDays`) — so it stops
being "never" and becomes "a quarter, then gone." That is the policy working, not a cleanup.

---

## 2. Brad's decision — the 191 MB of Chrome profiles in history

Already untracked going forward (`26b4cfd4`). Still in the pack, still on the remote, and the remote
is `github.com/Schweino/ThriftyCrew` — **Brad to confirm it is private** (`gh` is not on this box).

Two separate questions, and they have different answers:

**2a. Size.** Removing it halves the pack. Procedure, in order, because the order is the safety:

1. **Remove the ten worktrees first** (`git worktree list` shows 10). A worktree holds refs that pin
   the old objects; a rewrite with worktrees attached leaves 191 MB reachable and the force-push
   half-done. Part 1 of the cores work already found they were stale branches; most can go with
   `git worktree remove`. Any with uncommitted work: Brad looks first.
2. `git filter-repo --path grocery/out/browser-profiles --invert-paths` (not `filter-branch`; it is
   deprecated and slow). This rewrites every commit since 08-22 — **~10 commits**, all recent, all
   Brad's or the bot's.
3. `git push --force-with-lease origin main`. The cloud runner (`daily.yml`) clones fresh every run,
   so it needs nothing. Any *other* clone of this repo must re-clone.
4. `git gc --prune=now --aggressive` locally; the remote compacts on its own.

**2b. Credential.** `seed-profile-from-chrome.ps1:21` says what the profile is: *"Brad on those sites
until the cookies expire. Delete out\browser-profiles\<store>\ to revoke it."* If the repo has ever
been public, or if Brad would rather not reason about who could have cloned it in 48 hours, the
clean answer is: **re-seed the three profiles after the rewrite** (`seed-profile-from-chrome.ps1
-Store fareway,samsclub,walmart`). New cookies; the old ones in the old pack are then inert. Ten
minutes of attended Chrome. Recommended regardless of visibility — it is the only step that makes the
question moot.

**Not doing 2a means:** every clone carries 191 MB of cookies forever, and the repo's storage problem
is permanently "solved" by a `.gitignore` line that hides it.

---

## 3. Stay clean — the structural fix, so this is the last time

### 3.1 The daily commit sweeps `grocery/out`; it should allowlist, or at least *gate*

`capture-run.ps1:546`: `$inputPaths = @('grocery/out', …)` then `git add -A -- $paths`. Under a
directory that is swept, `.gitignore` is the **only** defence, and it is an exclusion list: anything
new is tracked by default. That is how 4,388 files went in unnoticed in one commit, and it will
happen again the next time a tool writes a new subdirectory under `out/`.

Two fixes, both cheap, and the plan recommends **both**:

**The gate (do first — general, catches every future class):** before `git commit`, count what is
staged. If a single daily commit would add **more than 300 new files or more than 25 MB**, refuse,
print the top offenders by directory, and exit 3 — the estate's could-not-evaluate code. `d2a864c0`
was 4,388 files / 797,640 insertions; today's normal commit was 426 files and most of those were
profile cache churn. The threshold is not precise and does not need to be: it separates "a day's
prices" from "a directory that should not be here" by an order of magnitude. Same shape as the
coverage ratchet — a number that would have fired on the incident and stays silent on a normal day.

**The allowlist (do second — it is the actual fix):** replace `'grocery/out'` in `$inputPaths` with
the enumerated families that belong in git. `prune-out.ps1` already **is** that enumeration — every
family listed there had its readers counted before it was listed. Staging by the same list closes the
loop: a family is tracked because something reads it, or it is not tracked at all. New subdirectories
under `out/` then default to *untracked*, and adding one to git becomes a decision someone defends in
a diff — the `detector-manual-allowlist` rule, applied to storage.

### 3.2 A `test-auditors` check that the ignore list covers the known-volatile shapes

One check, a handful of lines: assert that `.gitignore` ignores `__pycache__/`, `*.pyc`,
`grocery/out/browser-profiles/`, `grocery/out/archive/`, `sidecar/.venv/`, `sidecar/models/` (the
weights — the three `training-card.json` files are tracked on purpose and stay), and that **no
tracked file** matches `__pycache__|\.pyc$|browser-profiles`. It is the "watcher for the thing that
already bit us" pattern this estate uses everywhere else; a regression reads as a failed check at
change time, not as a 395 MB pack three weeks later.

### 3.3 The opposite gap — data we are supposed to keep and are dropping

`.gitignore:106`: *"provenance JSONL ARE tracked: they are the evaluation record and the audit."*
But `graph/provenance/` is **not in `$inputPaths`**, so the bot never stages it:

```
 M graph/provenance/2026-08-21.jsonl      <- modified, never committed
?? graph/provenance/2026-08-22.jsonl      <- never committed
?? graph/provenance/2026-08-23.jsonl      <- never committed
```

We kept 191 MB of cookies and dropped the audit record. **Do:** add `'graph/provenance'` to
`$inputPaths` next to `'graph/identity'`, which is there for exactly the stated reason ("if it is not
staged here it never leaves this PC"). One line. This is the "stay clean" rule in the other direction:
clean means *the right things are tracked*, not just that the wrong things are not.

---

## 4. Looks like waste, is not — so nobody "cleans" it

| | disk | in git | why it stays |
|---|---|---|---|
| `grocery/out/regular` | 399 MB | 30 MB | the 90-day union window (`MaxCarryDays`); only 41 days in, **will double**, and is cheap packed |
| `grocery/out/captures` | 831 MB | ignored | raw sessions, archived at 14 d by policy |
| `sidecar/models` | 6.4 GB | ignored (3 cards tracked) | model weights; re-downloadable |
| `sidecar/.venv` | 4.6 GB | ignored | regenerable from requirements |
| `media/videos` | 2.2 GB, 1,072 files | ignored | **Brad's content.** Nothing in the build references it — so either it is already hosted elsewhere, or this is the only copy. Worth one question; not this plan's to answer |
| `archive/site-backups/ghost-export-2026-08.zip` | 18 MB | tracked | a Ghost export is the one backup of the live site. Keep; maybe one per month, not one forever — a later decision |
| `brand/social` | — | 30 MB packed | assets; stable; fine |

The principle, stated once: **a file is waste if nothing reads it and nothing would miss it.**
`out/regular` fails the first test (twelve auditors read it). `out/archive` passes both — which is
why §1.3 gives it a TTL rather than leaving it at "never."

---

## 5. Order, and what each step must prove

| # | step | proves |
|---|---|---|
| 1 | §3.3 stage `graph/provenance` | `git status` shows the three files staged on the next run; the cloud clone has them |
| 2 | §1.1 `__pycache__` / `*.pyc` | `git ls-files \| grep pyc` is empty; `git status` shows no `??` pycache |
| 3 | §3.1 commit-size gate | a fixture that stages 400 dummy files exits 3 and names the directory; a normal day passes |
| 4 | §3.2 the ignore-coverage check | `test-auditors` green; deleting one ignore line turns it red |
| 5 | §1.3 `out/archive` TTL | `prune-out` (read-only mode) lists what would go; nothing under 90 d listed |
| 6 | §3.1 allowlist `$inputPaths` | a normal day's commit contains the same files as before, **minus nothing that any auditor reads** — diff two days' commit file-lists |
| 7 | §2 history rewrite + re-seed | **Brad's go first.** After: pack < 200 MB, `git log --all -- grocery/out/browser-profiles` empty, three profiles re-seeded and a browser capture succeeds |

Steps 1–6 are unattended and each is its own commit. Step 7 is a force-push and ten minutes of
attended Chrome, and it waits for a yes.
