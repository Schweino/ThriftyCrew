# A paper state-space model of the gate-slot ticket queue

Written 2026-09-12, backlog I158, whose first rung is explicitly **paper rather than a tool**. No
model checker is proposed here and none is installed. The point of the exercise is to find out
whether the protocol in `lib\gate-slots.ps1` can be written down as a transition system with two
stated properties, and whether that would have caught anything the 29 existing self-test cases did
not. It can, and it would have caught two of the three founding defects.

**Read `lib\gate-slots.ps1`'s own header first.** It is the source, this is a restatement, and where
the two disagree the header wins.

## 1. Why this protocol and not the other two

It is the only place in this tree where the estate **implements** a concurrent protocol rather than
calling a primitive. Several OS processes, shared state in the filesystem, and a hand-written
admission rule.

The other two candidates were argued out rather than skipped:

- **The ledger locks (`lib/ledger-lock.ps1`).** The protocol is "take one named mutex, do the whole
  read-modify-write inside it, release". One lock means **no lock-order cycle is expressible**, so
  the classic deadlock property is vacuously true and there is nothing for a model to search. Its
  reentrancy is the Windows mutex counting its owner's acquisitions, not estate code.
- **The promote and demote ladders.** Sequential, one writer, no interleaving to enumerate.

And one recorded defect in the ledger family is worth naming because it bounds what ANY model of
this kind is worth: `Move-Item -Force` refusing **inside** a held lock, because a lock-free reader
held the file shared ReadWrite without Delete. That is a Windows file-sharing fact, not a property of
the protocol, and no state-space model of the protocol contains it. A model that had been built and
passed would have said nothing about the defect that actually lost writes.

## 2. The components and their state

Three kinds of component. `N` waiters, `S` slots, one queue.

| Variable | Domain | Meaning |
|---|---|---|
| `loc[w]` | `idle`, `ticketed`, `head`, `holding`, `releasing` | where waiter `w` is |
| `slot[s]` | free, or the id of the waiter holding it | one named mutex per slot |
| `ticket[w]` | absent, or an arrival tick | the file, named for arrival time |
| `alive[w]` | true, false | models a killed waiter, which is the case the mutex exists for |

The queue order is the permutation of live tickets sorted by arrival tick. It is derived, not stored.

## 3. The transitions, as the header states them

1. `idle -> holding` when a waiter finds free slots **and no ticket is live**.
2. `idle -> ticketed`: take the ticket MUTEX, then write the ticket FILE. The order matters and is
   part of the protocol: no probe may see a ticket whose owner is still creating it.
3. `ticketed -> head` when this waiter's tick is the oldest among live tickets.
4. `head -> holding` when a slot is free. Takes as many as it wants, up to the budget.
5. `holding -> releasing -> idle`, dropping every slot and the ticket.
6. `alive[w] := false` at any point. Its ticket mutex is abandoned, the next probe takes it, the
   file is swept. **Liveness is the mutex and never the file** is a protocol rule, so a model that
   reads the file to decide liveness is modelling the wrong thing.
7. A holder may NOT take a further slot while any ticket is live. This is transition 1 with the
   extra guard, and defect 3 below is exactly its absence.

## 4. The two properties

**SAFETY.** At every reachable state, the number of slots held across all waiters is at most the
budget. Formally: `|{s : slot[s] != free}| <= S`, invariantly.

**FAIRNESS, and it is the one with the teeth.** If `ticket[a]` and `ticket[b]` are both live and
`a`'s tick is older, then `b` does not reach `holding` before `a` does. This is the property the
whole rewrite exists to provide, and it is the one no existing test can establish.

A third, **eventual service**, is deliberately NOT claimed: the header says so plainly. A waiter's
wait is unbounded by design, and only its ORDER is guaranteed. A model must not be asked to prove a
property the code does not claim, or it reports a real counterexample against an imagined spec.

## 5. The state space is small enough, with the arithmetic

`|locations|^N` times slot occupancy times ticket orderings.

- Three waiters, private 2-slot budget: `5^3 x 2^2 x 3!` = 125 x 4 x 6 = **3,000 states**.
- Three waiters, the real 10-slot budget: `5^3 x 2^10 x 3!` = 125 x 1,024 x 6 = **768,000 states**.

Both are trivially enumerable. **The 27-process case measured on 2026-09-11 never needs enumerating**,
because mutual-exclusion and ordering defects of this shape appear at two and three participants -
Peterson's algorithm is the standard demonstration that they do.

## 6. Would it have caught the three founding defects? Two yes, one partly

This is the only question that decides whether the exercise is worth anything, so it is answered
against the three causes the header records rather than in general.

| Defect | Caught by the model? |
|---|---|
| **1. NOT FIFO** - every waiter polled `WaitOne(0)` and whoever polled first after a release won | **YES.** A direct counterexample to the fairness property: a trace where `b` reaches `holding` with `a` ticketed and older. This is the defect the live probe needed 8 processes, 3 rounds and 400 ms spacing to demonstrate, and which the model finds at N=2. |
| **3. TOP-UP RACED THE QUEUE** - a run already holding slots took a freed one while runs holding nothing waited | **YES.** Transition 7's guard removed makes the same fairness property fail, again at N=2. |
| **2. FIXED DEADLINE** - 1,200 s of total waiting refused a run whose queue was still moving | **PARTLY.** The model has no clock. It can express "a waiter refuses while the count ahead of it is falling" as a property over the derived queue order, and that much would fail. It cannot express the wall-clock threshold that made the refusal happen, so the model would have named the shape and not the number. |

So the honest claim is **two founding defects found at two participants, and a third narrowed**, against
29 self-test cases that drive real processes and assert overlap. Those cases prove the good
interleavings happen; they cannot enumerate the ones nobody drove, and all three defects were
interleavings nobody drove. The mutant probe in the header (`Get-TcGateQueueAhead` neutered to answer
0, red in 5 of 29) measures the fixtures against **one** neutering, not against the reachable states.

## 7. What this model cannot see, stated because a clean model is not a proof of anything

- **The `Move-Item` share-mode defect**, per section 1. Outside the protocol entirely.
- **A queue that keeps moving and fills faster than it drains.** Everybody is served, nobody is
  refused, and every wait grows without bound. This is a RATE property, not a reachability one, and
  the header already says the only thing that could catch it is a floor on the drain rate, which
  does not exist. A model checker would report this protocol correct while the box became unusable.
- **A waiter that is alive but frozen.** The header lists it under NOT HANDLED. It is reachable in
  the model and the model would say the queue stops, which is what the code already does loudly.
- **Anything about the gates themselves.** The model knows only that a slot is held.

## 8. What is deliberately not done

No model checker is installed, no tool is proposed, and no gate is added. The routed course material
is `~/.claude/skills/software-craft/modelling-for-verification.md`, and that file's own verdict on
this estate was **mostly read-and-not-use with exactly one exception**, which is this protocol. This
document is that exception worked to its first rung and stopped, on purpose.

If anyone later wants the tool, the argument it has to beat is section 6: two defects at N=2, both
already fixed and both already fixtured, against the cost of maintaining a second specification of a
file that changes when the box's behaviour changes.
