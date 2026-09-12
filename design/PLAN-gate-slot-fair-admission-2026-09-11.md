> **NOT THE DESIGN THAT LANDED (header added 2026-09-12).** This is `claude/gate-slot-line`'s plan, kept as the
> rejected alternative so the decision is legible rather than lost. The fix that landed is `b1aab0424`; the queue
> in the tree is `lib/gate-slots.ps1` as it stands, not what this plan describes.
>
> **What this plan has that main does not, and why it was not taken.** Its line gives the HEAD one slot at a time
> while anyone is behind it, where main's head takes its whole want. That is a genuinely different trade - it
> spreads slots across more pushes and makes each one narrower, so every push gets going sooner and every push
> finishes later - and it is a queue DESIGN, not a missing case. Re-landing it would mean two queue
> implementations in one file, which the consolidation was explicitly not for. It is written down here so that
> if the current head-takes-everything rule is ever the thing to change, the alternative does not have to be
> re-derived. It carries no measurement of its own beyond the admission numbers.
>
> **Its measurement DID land**, and is the strongest of the four on admission order:
> `design/MEASURE-gate-slot-admission-2026-09-11.md`, with `ops/probe-gate-slot-admission.ps1` and
> `ops/report-gate-slot-admission.ps1`, the read-only live observer that produced it. Those are on main.

# PLAN: a line for the machine-wide gate worker slots (2026-09-11)

This changes what happens on EVERY push, because `pre-push` runs `ops\run-gates.ps1` and that run takes its
workers from `lib\gate-slots.ps1`'s budget of 10. Read this before the diff.

## What was measured, and what was not

`design\MEASURE-gate-slot-admission-2026-09-11.md` carries the bar, written before the run, and the numbers.
The short of it, on a real busy afternoon with 13 to 23 run-gates alive:

- **H1 CONFIRMED.** 25 of 54 freed slots (46%) went to a run that was already holding slots and growing, while
  runs holding none waited. In 13 of those 25 the oldest waiter had been waiting over ten minutes, and in 4 of
  them over nineteen - runs minutes from refusing their push, losing the slot to a run that already had one.
- **H2 CONFIRMED.** The run admitted was the oldest waiter in 5 of 27 admissions (19%) by wait start, 3 of 27
  (11%) by process creation, where first come, first served reads 100%. There was no order at all: admission
  was whoever's 500 ms poll happened to land first, so a waiter's age bought it nothing.
- **A, overload: not confirmed and not refuted.** 0.80 arrivals/min against 0.69 services/min, with the
  projected first-come-first-served wait at 12.2 min inside the 20 minute limit. So the machine sat near its
  capacity, and a line does NOT add any. See "What this does not fix".
- **The cost in that window: 16 of 47 real runs (34%) exited 3 after about 1,205 s without ever holding a
  slot** - 16 pushes refused with no gate failing.
- **B, leaked or stuck holders: none.** Every slot was held by a live gate run doing work. One non-run-gates
  holder appeared, `ops\run-daemon-battery.ps1`, which takes a slot from this same budget on purpose.

## The change

A LINE, in `lib\gate-slots.ps1`. The slots stay exactly what they are: 10 named mutexes, the only thing that
bounds the machine. The line only decides who gets a freed one.

1. **A ticket.** A run that cannot take a slot at once, or that finds anyone already in line, writes a ticket
   file into a queue directory, named by its arrival time, and holds a named mutex for as long as it waits.
   A ticket is live exactly while its mutex is held, so a killed run's ticket dies with it and the next
   reader reaps the file. Nothing can leave a stale file that blocks the line.
2. **Only the head may take a slot**, and while anyone is behind it, it takes ONE and leaves the rest. A run
   at width 1 is also the cheapest way to serve runs: the gate suite costs about 370 s of work run serially
   and about 580 s at width 16, so spreading the budget across more runs raises throughput rather than
   lowering it (`design\MEASURE-gate-cost-2026-09-09.md`).
3. **A growing run gives way.** `Add-TcGateSlots` takes nothing while anyone is in line, and counts the call
   in `$Lease.Deferred`, which `run-gates` prints. A run that holds slots is ahead of nobody.
4. **Deliberate load waits behind pushes.** An `-Exact` request (`ops\cpu-load.ps1`) takes no ticket and
   tries only while the line is empty. This is a deliberate behaviour change: under a sustained queue a load
   test now refuses with its existing exit 3 rather than taking cores a waiting push could use.
5. **A frozen waiter cannot stall the line.** A waiter touches its ticket on every poll; a live ticket
   untouched for `$TcGateTicketStaleSec` (120 s, registered in `docs\CONTROL-CONSTANTS.md`) is passed over
   and KEPT, so a run that resumes has its place back.

6. **A run never reads one of its own tickets as dead.** Found by running the real line once rather than only
   the fixtures: a mutex is re-entrant for its owner, so a reader probing its own ticket is granted it, calls
   it dead and REAPS ITS OWN PLACE IN LINE, silently. `Enter` never did this (it compares ticket names and so
   passes over its own), but it was one stray call away, so the process now remembers the tickets it holds.

Rejected alternatives, and why:

- **A kernel wait on one turnstile mutex.** No filesystem, but Windows does not guarantee the order waiters
  are released, and PowerShell's STA message pumping can drop a thread out of the wait queue and back in.
  The order would then be untestable by anything but a stopwatch.
- **Grow only after a waiter-free window.** Cheaper to write, but it fixes only H1. The measurement showed
  H2 as well: with no order, a waiter's age buys nothing even when no growing run is involved.
- **A shared sequence counter in a named section.** Creating a `Global\` section object needs
  SeCreateGlobalPrivilege, which these sessions do not have.

## What this does not fix, and what it costs

- **It adds no capacity.** When runs arrive faster than 10 slots serve them, the line changes WHO waits
  longest, not how many time out. The measured arrival and service rates are close enough that the honest
  statement is: a line makes the wait ORDERLY and bounded by position, and the 20 minute refusals will only
  go away if the arrival rate falls or the service rate rises. Both are Brad's calls, and both are outside
  this change: fewer concurrent pushes, a cheaper gate suite, or a bigger budget than 10 (his ruling).
- **Mixed versions during rollout.** A run from a checkout older than this commit ignores the line. It
  cannot exceed the budget - the mutexes still bound it - but it can jump the queue, so the line is fully
  in force only once the sessions on the box are running this code.
- **A queue directory outside the repo**, one per user account, under LocalApplicationData. A scheduled task
  running as another account would keep its own line and compete as today.
- **Cost per poll**: one directory listing and one mutex open, stopping at the first live ticket.

## The tests, and how they are proven

In `lib\gate-slots.ps1 -SelfTest`, which `run-gates` runs on every push. The existing 16 cases are untouched.
The new ones are proven by rendezvous and recorded ordering, never by a wall-clock bar
(`.claude\rules\ops-and-gates.md`): each run in line is another process, and a STUB holds a place in line
without ever polling a slot, which is what makes the ordering deterministic rather than a race between polls.

- MUST FIRE, the one the line exists for: a run holding slots does not top up into a FREE slot while another
  run waits - and the slot is proven free by another process taking it straight after.
- MUST FIRE: a run arriving behind a run in line is refused with every slot free.
- MUST FIRE: two runs in line and two slots freed - the head takes one, the run behind takes the other.
- MUST FIRE: a frozen ticket (alive, untouched past the limit) does not stall the line, and is kept.
- MUST FIRE: an exact request does not jump the line.
- CLEAN TWINS: the waiter gets the slot the moment the run ahead leaves, while the growing run tops up every
  20 ms throughout; growth resumes once the line empties; a killed head does not block; a live waiter keeps
  its ticket fresh; nobody leaves a ticket behind.

The suite also now runs its cases under `Stop` inside a try whose catch is a counted failure, and asserts the
number of cases it ran. It had neither, and the first draft of these cases went GREEN at 21 of 27 with exit 0
after a crash - the same shape `.claude\rules\ops-and-gates.md` names.

Mutation-probed with single compiling mutants from a temp mirror, the original verified byte-identical by
md5 afterwards; the results are in the commit message and in `design\MEASURE-gate-slot-admission-2026-09-11.md`.
