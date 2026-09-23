# Lane: pd-backlog, W3.1 of design/PLAN-push-derived-conflicts-2026-09-23.md, 2026-09-23

Two things found while building W3.1 and deliberately left outside it.

## the backlog merge accepts a NEW finding whose state only begins with a state word, and the gate then fails the backlog

`OPEN` `queue-7` `2-WAY` `RUNG1 BUILD`

**Measured 2026-09-23** in a temp backlog and drop box (the real backlog was not touched). A finding file whose state
line reads `` `DONE-ish` `queue-7` `` merged with exit 0 as I41, and `ops/audit-backlog-status.ps1 -Backlog <that
copy>` then exited 2 with `I41: declares no state`. The cause is `Test-State` in `ops/merge-backlog-inbox.ps1`: it
accepts any tag matching `^<STATE>\b`, so `DONE-ish`, `DONE:` and `OPEN.` all pass it, while the gate accepts only
the bare state, `STATE - detail` or `STATE <date>`. The same function is in the pre-W3.1 blob
(`371c5a8787fbf9c5c5b26dbf1c1b7f12e30f13a1`), so this is not new.

W3.1 closed it for UPDATE blocks only: each UPDATE file is applied to a temp copy and judged by the gate before it
lands, so the same tag in an UPDATE is quarantined. New findings are still judged by the merge's own parser alone.

The fix is one of two, and the second is the one that cannot drift: make `Test-State` apply the gate's exact rule, or
append each accepted finding file's headings to a temp copy and run the same per-file gate W3.1 runs for updates. The
first is a copy of a rule, the kind `ops/merge-backlog-inbox.ps1`'s own header warns diverges; the second reuses
`Invoke-TcBacklogGate`, costs one in-process gate run per finding file, and needs a MUST FIRE for `DONE-ish` and a
CLEAN TWIN for `DONE - detail`.

## the script census still records the backlog merge as uncalled on purpose because two runs would race, which W3.1 made false and W3.4 will make doubly false

`OPEN` `queue-7` `2-WAY` `RUNG1 DOC`

`grocery/audit-script-census.ps1`'s `KNOWN` entry for `ops\merge-backlog-inbox.ps1` (line 78 at `f33d11829`) gives the
reason it is by hand as: id allocation is a one-writer operation, "two runs racing would mint the same id twice", and
"A scheduled run would do both unattended". Since W3.1 a real merge holds `lib/ledger-lock.ps1`'s lock on the backlog
path across its inbox read, allocation, write and consume, so two runs can no longer race, and W3.4 adds exactly the
scheduled run the entry says must not exist. The entry is text, so nothing goes red; it just stops being true.

The repair belongs in W3.4's own commit, which is the change that gives the merge a production caller: rewrite the
reason, or drop the entry if the census then counts the new task script as the caller. Not done in W3.1, because that
lane owned only the merge, its README and the status audit.
