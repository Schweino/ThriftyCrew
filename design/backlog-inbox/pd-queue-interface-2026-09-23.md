# pd-queue interface: lib/chain-queue.ps1 for the push-main lane (2026-09-23)

Written by the chain-queue lane of `design/PLAN-push-derived-conflicts-2026-09-23.md` (W9.2, section 16.3),
branch `feat/pd-queue`, FIRST so the push-main lane can build against it before the library lands. This is
the contract; the library's header repeats it. The library lands TOGETHER with push-main's W9.2 integration,
because `grocery/audit-script-census.ps1` calls a library with no caller an orphan.

Plan: design/PLAN-push-derived-conflicts-2026-09-23.md W9.2 W6.1

## What it is, in one paragraph

An ordered, machine-wide queue of TICKETS for chain-touching pushes. It is `lib/gate-slots.ps1`'s ticket
mechanism (`New-TcGateTicket`, `Test-TcGateTicketLive`, `Remove-TcGateTicket`: arrival order by ticket name,
liveness by the ticket's MUTEX, never its file) with a JSON record beside each ticket. It NEVER calls
`Enter-TcGateSlots`: it grants no slot and excludes nobody from running a leg. The one thing it defers is a
member's SWAP until every ticket ahead of it has landed, left or died. Lock order position `0b` (16.6):
outside the push lock, the gate slots and the rehearsal slots, and never held by anything that waits on it.

## Dot-source

```powershell
. (Join-Path $repoRoot 'lib\chain-queue.ps1')   # also loads lib\gate-slots.ps1 and lib\atomic-write.ps1
```

No `param()` block, so it cannot reset the caller's `-SelfTest` (the `lib/guard-contract.ps1` reason).

## Constants (script scope, read them, do not copy them)

| Name | Value | Meaning |
|---|---|---|
| `$script:TcChainQueuePrefix` | `Global\tc-chain-queue-` | the production mutex prefix; ticket mutexes are `<prefix>q-<ticket>` |
| `$script:TcChainQueueRoot` | `%LOCALAPPDATA%\ThriftyCrew\chain-queue` | the production queue root; the queue dir is `Get-TcGateQueueDir` of the prefix under it |
| `$script:TcChainQueueEnvVar` | `TC_CHAIN_QUEUE_HOLDER` | the holder token a member exports (step 10) |
| `$script:TcChainQueueSelfTestEnvVar` | `TC_CHAIN_QUEUE_SELFTEST` | when set to anything non-empty, every call REFUSES the production prefix and root (throws) |
| `$script:TcChainQueueStallSec` | `3600` | step 8's bound on time WITHOUT QUEUE MOVEMENT; first plausible, not swept |
| `$script:TcChainQueueReportSec` | `300` | how often a waiter reports its position and depth |
| `$script:TcChainQueuePollMs` | `1000` | how often a waiter re-reads the queue |

## Functions

Every function below NEVER throws except `Assert-TcChainQueueInstance` (and anything that calls it first,
which is `Join-TcChainQueue`, `Get-TcChainQueueLive` and `Test-TcChainQueueHolderToken`): a queue that
cannot be created, read or written degrades to `queue=error`, and the push proceeds as the W2.2R path does.

### `Assert-TcChainQueueInstance -Prefix <s> -QueueRoot <s>`
Throws when `$env:TC_CHAIN_QUEUE_SELFTEST` is non-empty and the prefix is the production prefix or the root is
the production root (ordinal, case-insensitive; trailing separators trimmed). push-main's `-SelfTest` sets the
variable, so a fixture that forgets the seam goes red loudly instead of queueing real pushes behind it.

### `Join-TcChainQueue -Checkout <path> -Base <sha> -Range <string[]> [-Mode live|off] [-Prefix] [-QueueRoot]`
Call it once, after the round-1 sync and the seed, when the `-ForPush` child reports the push chain-touching
(W6.0's union), INCLUDING under `-NoRehearsal` or `TC_NO_REHEARSAL`. A non-chain push does not call it and
records `queue=not-chain`. `-Base` is the origin sha the worktree was rebased onto; `-Range` is
`git rev-list --reverse <merge-base>..HEAD`, oldest first.

Returns a MEMBER object. Read `.Queue`:
- `joined`: a ticket is held ON THIS THREAD and `$env:TC_CHAIN_QUEUE_HOLDER` is exported. `.Position` is the
  number of live tickets ahead at join. `.Token` is the exported token.
- `off`: `-Mode off`. Nothing was created, not even the queue directory, and no ticket exists. The rollback.
- `error`: the queue could not be joined; `.Reason` says why in words. Nothing is held.

The record is written BEFORE the call returns and before any stack is read (it is the pointed-to object).
Fields: `ticket`, `pid`, `checkout`, `base`, `range`, `state` (`rehearsing` at join), `rh_key` (empty at join),
`updated_utc`, `seq` (bumped on every rewrite).

### `New-TcChainStackFile -Member <m> -Origin <sha> -Path <file>`
Reads every live ticket ahead, oldest first, and writes the stack file W9.1 step 1 reads: LINE 1 is `-Origin`,
then every sha of the `range` of each ahead ticket whose state is not `landed` or `left`, in ticket order,
oldest first. 40-hex shas only, one per line, LF, no BOM, no comments, trailing LF. The member's OWN range is
NOT in the file: rehearse-chain applies `<merge-base>..<Commit>` after the listed commits.

Returns a STACK object: `.Ok`, `.Path`, `.Base`, `.Ahead` (each `Name`, `Pid`, `Checkout`, `Range`, `RhKey`,
`Seq`), `.Lines`, `.Reason`. `.Ok = $false` when an ahead ticket's record could not be read within its hang
guard: the caller then treats the queue as `error` (`Exit-TcChainQueue -State left`, proceed as W2.2R).
Each call bumps `.Stacks` on the member; `.Restacks` is `.Stacks - 1`.

THE WORKTREE IS NEVER REBASED ONTO THE STACK (step 4, mutant M22). Pass `-StackFile $stack.Path` to the
rehearsal starter; only the rehearsal's own clone applies the ahead commits.

### `Set-TcChainQueueState -Member <m> [-State <s>] [-Base <sha>] [-Range <string[]>] [-RhKey <key>]`
Rewrites the member's record. Returns `$true`, or `$false` when it could not write (degrade: the queue keeps
working on the last record; a caller may record it but must not refuse). States, in the order push-main sets
them: `rehearsing` (join), `ready` (legs and rehearsal passed, about to wait for the head), `swapping` (the head
is clear, about to take the push lock), then the final `landed` or `left`, which only `Exit-TcChainQueue` writes.
Call it with `-Base -Range` after EVERY rebase of the worktree (catch-up, hand-back, in-lock), and with `-RhKey`
when a rehearsal verdict for the stacked tip is recorded or found.

### `Wait-TcChainQueueHead -Member <m> [-Stack <st>] [-StallSec 3600] [-PollMs 1000] [-ReportEverySec 300] [-OnReport <sb>]`
Blocks until every ticket ahead is `landed`, `left` or dead, holding NOTHING but the ticket (no gate slot, no
rehearsal slot, no push lock). Returns `.Outcome`:
- `head`: take the swap. Set `swapping`, then `Enter-TcPushLock`.
- `restack`: a ticket ahead in `-Stack` turned `left`, died without landing, or rewrote its `rh_key` (or, while
  it has none, its `range`). Build a new stack file, rehearse once more, call Wait again. A ticket ahead that
  LANDED is not a restack.
- `timeout`: the count of uncleared tickets ahead did not fall for `-StallSec`. `.Head` names the ticket that
  was at the head (`Name`, `Pid`, `Checkout`, `State`). Record `queue=timeout` and `queue_ahead`, then
  `Exit-TcChainQueue -State left` and proceed as W2.2R. NEVER a refusal.
- `error`: the queue could not be read; record `queue=error`, leave, proceed as W2.2R.
`-OnReport { param($Position, $Depth, $WaitedSec) ... }` runs every `-ReportEverySec`; its output goes to
Out-Default, never into the return. `.WaitedMs` is this call's wait, and the member accumulates it in `.WaitMs`.

### `Resolve-TcChainStackCommit -Stack <st> -Sha <sha>` and `Set-TcChainStackConflict -Member <m> -Stack <st> -Sha <sha> [-Files <string[]>]`
When the rehearsal reports `blind=stack-conflict` and the commit it stopped on, Resolve names the ahead ticket
whose range holds that sha (or `$null` when it is the member's own commit), and Set records `stack=conflict` and
`.ConflictWith` (`Name`, `Pid`, `Checkout`, `Files`). The member KEEPS ITS PLACE and waits: if that ticket leaves,
Wait returns `restack`; if it lands, the member's catch-up rebase refuses with `phase=catchup`.

### `Exit-TcChainQueue -Member <m> [-State landed|left]`
Writes the final state into the record, deletes the `.ticket` file, releases and disposes the ticket mutex, and
removes `$env:TC_CHAIN_QUEUE_HOLDER`. Default `left`. Safe with `$null`, safe twice, safe on `off` and `error`.
Call it with `landed` only after `git push` exited 0 and the remote holds the sha; call it with `left` on EVERY
other exit, including a refusal, a timeout and a throw: put a `left` call in push-main's `finally`, because a
second call is a no-op. SAME THREAD as the join (a mutex belongs to its thread).
The record is KEPT after exit (a ticket that landed must stay distinguishable from one that died) and swept by
the next join once it is older than 24 hours.

### `Test-TcChainQueueHolderToken -Token <s> [-Prefix] [-QueueRoot]`
For W8.3's zero-wait probe in the hook. `$true` when the token (`<pid>|<ticket>|<prefix>`) names THIS queue
instance, its pid is alive and its ticket mutex is held. A token on another prefix, a dead pid or a released
ticket is `$false`. Acquires nothing that is held.

### `Get-TcChainQueueLive [-Prefix] [-QueueRoot]`
The live tickets, oldest first, each `Name`, `Pid`, `Checkout`, `State`. For W8.3: "while any live ticket
exists". Probes from the caller's thread, so never call it from the thread that holds a ticket and expect to
see your own (a mutex is re-entrant for its owner, so your own ticket reads as dead to you).

### `Get-TcChainQueueRow -Member <m>`
The step 11 row fields as an ordered hashtable, to merge into the W0.1R row: `queue` (`joined`, `off`,
`error`, `timeout`, or what the caller set, see below), `queue_pos`, `queue_wait_ms`, `queue_ahead` (the head's
`pid:checkout` at a timeout, else empty), `stacked_on` (`<base sha9>+<n ahead ranges>` of the LAST stack),
`restacks`, `stack` (`ok`, `conflict`, or `none` when no stack was built). Wait sets `.Queue` to `timeout` or
`error` itself when it returns one of those, so the row is right without the caller touching it. A non-chain
push records `queue=not-chain` without calling Join at all.

## What push-main does at each step (16.3 W9.2)

1. Chain-touching (incl. `-NoRehearsal`)? `$cq = Join-TcChainQueue -Mode $ChainQueue ...`. Not chain: row
   `queue=not-chain`, no call.
2. `joined`: `$st = New-TcChainStackFile -Member $cq -Origin $origin -Path <per-run file>`; `.Ok` false means
   leave and degrade. Start the rehearsal with `-ForPush -StackFile $st.Path` (W9.3's starter). A
   `-NoRehearsal` member still builds no stack file if it rehearses nothing, but it keeps its ticket.
3. Legs red, or any refusal: `Exit-TcChainQueue -Member $cq -State left` BEFORE releasing anything else.
4. Legs and rehearsal passed: `Set-TcChainQueueState -Member $cq -State ready -RhKey <stacked key>`.
5. Catch-up rebase: `Set-TcChainQueueState -Member $cq -Base <origin> -Range <new range>`.
6. `Wait-TcChainQueueHead -Member $cq -Stack $st`: loop on `restack` (new stack, rehearse, `-RhKey`), leave and
   degrade on `timeout` or `error`, and on `head` set `swapping` and go to W9.4's swap.
7. Every rebase inside or around the lock: `Set-TcChainQueueState -Base -Range` again, so a member behind sees
   the new range with the same `rh_key` and does NOT restack.
8. `git push` exit 0: `Exit-TcChainQueue -State landed`, then release the push lock. Refused inside the lock:
   `Exit-TcChainQueue -State left`.
9. `finally`: `Exit-TcChainQueue -Member $cq -State left` (no-op after a landed exit).
10. Row: merge `Get-TcChainQueueRow -Member $cq`.
11. `-SelfTest`: set `$env:TC_CHAIN_QUEUE_SELFTEST = '1'` and pass a private `Local\` prefix and a per-run root
    (both seams), or every Join throws.

The holder token is exported by Join and removed by Exit, so every child push-main starts in between (the
`git push` and its hook) inherits it; the hook's W8.3 probe checks it with `Test-TcChainQueueHolderToken`.

## The bound, stated beside the fix

The queue ORDERS chain landings and adds no rehearsal capacity. Ceiling: 6 rehearsal slots over 800 to 1,240 s
is about 17 to 27 chain landings an hour (review), against about 4.2 an hour offered at the 09-19 peak (plan).
Cost: head-of-line, a member ready first waits for the one ahead, up to its remaining rehearsal (about 21
minutes, review). Order decides which pushes wait, never how many land.

## The drill

`ops/drill-chain-queue.ps1 -Drill -Rounds 3` runs the three-push sandbox drill (16.3 W9.2 step 12): a temp bare
remote, three clones, a private queue prefix and root, stub legs and a rehearsal stub that records what it
judged, driven by a REFERENCE RUNNER that follows the sequence above. `-Runner <script>` swaps the reference
runner for a real one (push-main after integration) through the same config file. Its `-SelfTest` carries the
push-level W9.2 fixtures; `lib/chain-queue.ps1 -SelfTest` carries the library-level ones.
