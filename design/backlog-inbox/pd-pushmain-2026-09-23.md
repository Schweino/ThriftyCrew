# Lane: pd-pushmain (the push-main items of design/PLAN-push-derived-conflicts-2026-09-23.md), 2026-09-23

Filed by the lane that owns `ops/push-main.ps1` for that plan, for the sibling lanes and for Brad. Each entry is a
finding made while building, outside this lane's own files.

## rehearse-chain's -forpush should say when its covering verdict was an early one, or b22 cannot be read

`OPEN` `queue-7` `2-WAY` `RUNG1 BUILD`

**What is missing.** W9.1 step 7 asks push-main to record `early_hit` on every chain-touching row: `yes` when the first
`-ForPush` of the run found a covering verdict whose record says `early`. B22 (the live early-verdict hit rate, the bar
Brad ruled on at 30%) is read from exactly that field. The verdict record carries `early` (rehearse-chain's W9.1 half,
on `feat/pd-rehearse2`), but `-ForPush` prints only `chain-rehearsal: PASSED - <n> chain script(s) changed and this
content was rehearsed over data from <date> ...` and `CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=rehearsed-pass`,
neither of which says whether the verdict it read was an early one. push-main cannot read the record itself without a
second copy of Get-RhManifestSet (the key), which is the one thing the design forbids.

**What push-main does meanwhile** (`Get-TcEarlyHit`, `ops/push-main.ps1`): it reads an `early=yes|no` token on the LAST
`CHAIN-REHEARSAL-CHECK-COMPLETE` line, or a `PASSED` line naming an early rehearsal. Without either, a chain push that
reused a verdict records `early_hit=unknown`, never a guessed `yes` or `no`; a push that rehearsed now records `no`, and
a push touching no member records `not-chain`.

**The ask, for the rehearse-chain lane:** append ` early=yes` or ` early=no` to `-ForPush`'s (and `-CheckPush`'s)
`CHAIN-REHEARSAL-CHECK-COMPLETE` line when a verdict decided the outcome, taken from that verdict's own record. The
marker's existing readers (push-main's `Get-TcRehearsalOutcome`, the hook's outcome read, W0.3's probe) match
`code=\d+ outcome=(\S+)` and are unaffected by a trailing token. Until it lands, B22 reads `unknown` for every reuse.
