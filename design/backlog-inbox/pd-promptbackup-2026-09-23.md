# Lane: pd-promptbackup, W8.4 of design/PLAN-push-derived-conflicts-2026-09-23.md, 2026-09-23

Filed by the W8.4 build lane (Brad's ruling D15). Each finding below sits in a file this lane did not own, so it is
recorded here rather than fixed.

## the daily chain's call of audit-prompt-backup -Daily has no wiring case in check-ad-cycles' own self-test

`OPEN` `queue-pd-promptbackup` `2-WAY` `RUNG1 BUILD`

**Source.** W8.4 made `ops/audit-prompt-backup.ps1`'s default run (the one run-gates makes on every push) judge only
what a push changed, and moved the whole-mirror check to `-Daily`, which `grocery/check-ad-cycles.ps1` runs and pages
on. The push mode is safe only while that call runs. Nothing fails if a later edit drops `-Daily` from it or removes
the block: the audit's own self-test cannot hold it, because parsing the chain from there pulls the chain's whole
input walk into that suite's gate key (measured 2026-09-23 with `Get-TcGateInputKey`: 1,738 files, 1,096 of them data
files including `grocery/out/comparison-*.json`, 3,991 ms, against 4 files and 194 ms without it).

**The first rung.** Add one case to `check-ad-cycles.ps1 -SelfTest`'s WIRING group, read off the parsed file as its
other wiring cases are: exactly one command outside the self-test runs `ops\audit-prompt-backup.ps1` with a
`-Daily` parameter, and its exit code reaches the `Send-Alert 'Ops: an agent prompt is not backed up'` branch. That
self-test is already unkeyable (it reads `grocery\out`), so the case costs no key. The detective half already exists:
bar B15 counts the days with a `PROMPT-BACKUP-COMPLETE` line from the daily block in `grocery/ad-cycle-log.txt`
(at least 13 of 14).

## two readers still describe the prompt-backup check as weekly, and test-auditors u109 now reads the push mode

`OPEN` `queue-pd-promptbackup` `2-WAY` `RUNG1 DOC`

**Source.** Read 2026-09-23 after W8.4, by `git grep -n -i "prompt-backup weekly\|agent prompt is not backed up"`
outside `design/` and `grocery/out/`.
- `grocery/ALERTS.md:78` lists *Ops: an agent prompt is not backed up* under "weekly estate checks". It is daily now,
  and pages only on a finding more than 24 hours old.
- `grocery/test-auditors.ps1:6368` (u109) says check-ad-cycles runs the audit weekly. It is daily now. And u109 runs
  the audit with no switch, which since W8.4 is the PUSH mode: in the main checkout, where HEAD is usually
  origin/main, it judges nothing as the push's own and its `Ok` line ("every agent prompt and scheduled-task SKILL is
  backed up") claims more than that run checked. Its HYGIENE arm (rc 2) now fires only for a finding the checkout's
  own unpushed commits caused.

**The first rung.** Change the two sentences. For u109, decide whether it should run `-Daily` (the daily floor, which
check-ad-cycles already pages on, so a second report of the same finding) or keep the push mode and reword its `Ok`
line to what it proved. Neither changes a verdict of the audit.

## run-gates' entry for audit-prompt-backup still says the push proves the whole mirror current and the scopes agreeing

`OPEN` `queue-pd-promptbackup` `2-WAY` `RUNG1 DOC`

**Source.** `ops/run-gates.ps1:327` registers the audit with `n = 'the only versioned copy of the agent prompts is
current, and the scopes agree'`, and the comment above it says the same. The first run-gates after W8.4, from the lane
worktree (exit 0, `RUN-GATES-COMPLETE pass=483 fail=0 noverdict=0`), printed that sentence beside `ok`. Since W8.4 the
push run proves only that nothing the push changed disagrees with its counterpart (its marker reads
`mode=push ... failed=0 review=N`), and whole-mirror currency is `-Daily`'s, in the daily chain. The entry was not
edited in W8.4 because a registration edit to run-gates.ps1 flushes every self-test key (the plan's D7) and the file
belonged to no lane of this build.

**The first rung.** Reword the `n` text and its comment the next time run-gates.ps1 is edited for another reason, so
the flush is paid once: for example `nothing this push changed under ops\prompt-backup or the prompt trees disagrees
with its counterpart; the whole mirror is judged daily by -Daily`.

## grocery/prompt-backup-weekly-stamp.txt is tracked and nothing reads or writes it any more

`OPEN` `queue-pd-promptbackup` `2-WAY` `RUNG1 READ`

**Source.** W8.4 replaced check-ad-cycles' weekly block, which read and wrote this stamp, with a daily one that uses
none. `git grep -n prompt-backup-weekly-stamp` outside `design/` and triage plans names no reader after the change.
It was deliberately NOT deleted in the same commit: the ~07:00 bot commits `grocery/` and rebases with `-X theirs`,
and a deletion landing while an older copy of check-ad-cycles still rewrites the stamp is the modify/delete conflict
`.claude/rules/grocery.md` records as aborting the bot's rebase.

**The first rung.** Once every checkout that runs the chain has pulled W8.4 (the main checkout is the one that
matters), delete the file in its own commit, or leave it and say so here.
