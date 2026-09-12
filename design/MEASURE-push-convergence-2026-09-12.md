# Can a push on this box converge? Measured 2026-09-12

**Harness:** `ops\probe-push-convergence.ps1` (committed with this document), reading
`lib\push-ledger.ps1`'s rows, the shared `refs/remotes/origin/main` reflog, and the retained
`%TEMP%\tc-prepush-*.log` files. Run it rather than quoting the numbers below.

**Commit it ran at:** `f31de0d16`, the commit that adds the harness, **as it LANDED on `origin/main`**.
Re-read the numbers before trusting them - this file's own rule is that a moved harness makes a verdict
unqualified, and this harness is hours old.

**And the hash had to be the landed one, which cost two refused pushes and is worth writing down.** This
document is in its own commit for the reason `design\MEASURE-ratchet-plain-run-writes-2026-09-12.md`
gives: a document cannot carry the hash of the commit that adds its harness, so the harness goes in one
commit and the document cites it from the next. That is necessary and it is not sufficient here, because
**`ops\push-main.ps1` rebases INSIDE the push lock**, which is the whole point of it - and a rebase
rewrites every commit on the branch, so the hash this document cited stopped existing on the way to the
remote. `ops\audit-conclusion-currency.ps1` then failed the push, correctly, inside the hook, where
nothing could re-cite it. Pushing the two commits together cannot work, and neither can citing a hash
that has not landed yet. **Land the harness first, read the hash the remote actually holds, then write
the document against it.** The same trap in its milder form is `f797255e5` "Cite the post-rebase hash,
because the rebase is what kept invalidating the citation"; under a wrapper that rebases for you there is
no post-rebase moment to cite from, only a post-LANDING one.

**Question, written before the run.** A brief reported three consecutive pushes on 2026-09-12 that each
waited for the machine-wide push lock (1,130 s, 1,313 s, 2,464 s), were then refused because
`refs/heads/main` had moved while they waited, and landed nothing in about 83 minutes. Is that still the
behaviour of the push path, and if not, when did it stop?

**Acceptance bar, written before the run.** The brief's failure is a REFUSAL AFTER A WAIT, which the gate
reports as `blind=push-cannot-land`. If that class is still being produced after the two reorders that
landed this morning, the order is still wrong and the wrapper is not enough. If it stopped at the reorder,
the order is already fixed and what is missing is the ability to SAY so without archaeology.

## What the push path actually did today

Three commits changed it, all before this brief was written:

| commit | landed | what it changed |
|---|---|---|
| `e73f3d940` | 2026-09-11 22:16 | the lock exists; the hook takes it at the TOP and holds it across the whole gate |
| `a6e724f36` | 2026-09-12 07:21 | the lock is taken AFTER the checks and held across the ref update only |
| `4ae8376f4` | 2026-09-12 08:45 | `ops\push-main.ps1` gates OUTSIDE the lock, then takes it for fetch, rebase and push |

The brief describes the order at `e73f3d940`: wait for the lock, then discover the remote moved, then
refuse. That order stood for about nine hours.

## 1. The refusal class stopped, and the retained logs date it

229 pre-push gate logs were retained in the 24 hours to 10:57. Read the denominator first: **the hook
DELETES its log on the path where the gate passed**, so this population is the refusals and the runs still
in flight, and not one landed push is in it. It can say which refusals happened and when; it cannot say
what fraction of pushes were refused.

| cause | retained logs | last seen |
|---|---|---|
| `push-cannot-land` | 54 | **2026-09-12 07:41** |
| `no-gate-worker-slot` | 46 | 2026-09-11 17:34 |
| no blind token (a red gate, or still running) | 130 | 2026-09-12 10:57 |

By hour, `push-cannot-land` ran 6 at 18:00, 10 at 19:00, 1 at 20:00, 5 at 21:00 on 2026-09-11, then 1 at
05:00, 18 at 06:00 and 13 at 07:00 on 2026-09-12, and **none after 07:41** - twenty minutes after
`a6e724f36` moved the lock off the checks. The class the brief describes is not being produced any more.

That is not the same as saying no push is ever beaten to the ref. Under the current order a plain
`git push` still gates for minutes and then queues, so main can move underneath it; what changes is that
git itself rejects it in seconds with "cannot lock ref" instead of the gate refusing it after a 20-minute
wait. `ops\push-main.ps1` is the path that cannot go stale, because it fetches and rebases INSIDE the lock.

## 2. How long a base stays fresh

From the `refs/remotes/origin/main` reflog, which is the one `.git` every worktree on this box shares, so
every landing from this box writes an entry:

- **95 landings over 23.92 h = 3.97 per hour** (fetch and pull entries excluded: they are a checkout
  catching up, not a landing).
- A freshly fetched base stays fresh for a **median of 621 s, p90 1,535 s, shortest 99 s**, over 94 gaps.

Read that against a critical window. A push whose window (gate plus queue) is longer than about ten
minutes is more likely than not to come out of it stale, and a retry restarts the same clock - which is
why the brief's three attempts could not converge and why no retry policy would have made them.

## 3. The wait, and staleness during it: NOT YET MEASURED, now recordable

This is the honest half. **Nothing recorded, per push, how long it waited or whether the remote moved
while it did.** `ops\hold-push-lock.ps1` wrote the wait into `<SignalDir>\state`, and `ops\hooks\pre-push`
deletes that directory on its way out. Every account of this so far, including the brief's three numbers,
came from one session reading its own terminal.

`lib\push-ledger.ps1` now appends one row per push - the wait, the lock state, `origin/main` before the
wait and at the grant, and how the push ended - from both `ops\hold-push-lock.ps1` (every hook push) and
`ops\push-main.ps1` (every wrapper push). The ledger was empty when this document was written, and the
report says NO ROWS rather than printing a zero, because a quiet ledger means nobody has pushed through an
instrumented checkout yet, not that nobody waited.

**A day of rows will answer it. Re-run the harness tomorrow.**

### The fixture pollution this found in its own first run

The first live run of the report read *"the remote MOVED while the push waited in 2 of 7"*. It was wrong,
and the way it was wrong is worth keeping: every row in the ledger was a FIXTURE row. Self-test cases in
`ops\hold-push-lock.ps1` and `ops\push-main.ps1` that did not pass a scratch ledger root wrote into the
production one, with real shas from temp clones that existed for a second. The repair is the estate's
existing rule - when code under test writes a real path BY DEFAULT, redirect the default SUITE-WIDE rather
than per fixture - so `TC_PUSH_LEDGER_ROOT` is set once at the top of each suite, and each suite now
asserts that no row carrying its own pid reached the production file. The polluted file was deleted.

## What is still not measured

- **How often a plain `git push` is rejected with "cannot lock ref" under the current order.** git writes
  that to the pushing session's terminal and nothing keeps it. The ledger records the wait and the
  staleness but not git's own rejection, so this remains unmeasured by anybody.
- **How many sessions use `ops\push-main.ps1` rather than `git push`.** The ledger's `event` field will
  answer it once rows accumulate; today it cannot.
- **Whether the 54 `push-cannot-land` refusals cost more than the pushes they prevented.** Each was cheap
  by design - seconds, before the gate ran - but each also meant a session re-queued.
