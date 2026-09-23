# Lane: sh-pc landing, W0.2 of design/PLAN-bot-checkout-self-heal-2026-09-23.md, 2026-09-23

Filed by W0.2's landing push, as the landing stage asks of every item that section 8 of the plan gives a bar. Section
8 gives W0.2 one bar, the mutant M9, and no live bar (B1 to B9 judge W1.1, W2.2, W3.1, W4.1 and W4.2). What W0.2
landed, by blob, because a rebase cannot move a blob: `lib/pipeline-commit.ps1` 1c3caad75e9cebd22a5781d28d86a39349e7c22c.

## read out bar m9 for w0.2: the snapshot back to M only must turn the w0.2 must fire red

`DONE` `queue-7`

**The bar, as section 8 wrote it before the run.** Mutant M9, "`Get-DirtyOwnedSnapshot` back to `M` only", must turn
W0.2's MUST FIRE red, from a temp mirror, one at a time, with the original md5-identical afterwards. A survivor means
the fixture is insensitive and the item is not done.

**Read out 2026-09-23, at landing, on the rebased tree.** The mutant made the `D` branch of `Get-DirtyOwnedSnapshot`
unreachable, in a temp mirror of `lib\` under `%TEMP%`, and ran `lib/pipeline-commit.ps1 -SelfTest` from it. Scratch
harness, described rather than committed because this is a one-off read at landing: `m9-probe.ps1`, hash-object
ee65a0af7cd75ad80af250be794f2ddafeb01e83.
- On the W0.2 blob above: exit 1, `SELF-TEST FAIL: 5 case(s) of 69 run`, among them the named MUST FIRE "a deletion
  present at start and still absent is NOT committed". Original md5 BB8BC5A5DD375AEF94B6629C6356A05C before and after,
  mirror removed.
- On the W3.2 blob that lands next (e9a1d1aae281ecbf40ff937f985333cc2c929891): exit 1, `SELF-TEST FAIL: 5 case(s) of
  82 run`, the same MUST FIRE red. Original md5 83E1697AC0AF41D5169688FF12D631EC before and after, mirror removed.
- The unmutated suite on the rebased W0.2 tree: exit 0, `SELF-TEST PASS: 69 of 69 cases`. The size gate that lifts
  capture-run's FOREIGN-HELD block over this lib: exit 0, `COMMIT-SIZE-GATE-COMPLETE cases=24 failed=0`.
  `lib/gate-input-key.ps1 -VerifyDeclared lib\pipeline-commit.ps1`: exit 0, `GATE-DECLARATIONS-VERIFIED 1 of 1`.

The lane ran the same mutant before this landing, with the same counts; the two runs above are this stage's own.
The line for section 13 of the plan: `M9: killed, 5 reds of 69 (W0.2 blob 1c3caad75e9c) and 5 of 82 (W3.2 blob
e9a1d1aae281), read 2026-09-23 at landing`.

## read out w0.2 on the first scheduled capture runs after it lands, 2026-09-24 and 2026-10-07

`OPEN` `queue-7` `2-WAY` `RUNG1 MEASURE`

**Why there is a live read at all.** Section 8 gives W0.2 no live bar, so the landing stage chose this one, written
before any run it judges. capture-run already calls `Get-DirtyOwnedSnapshot` and `Get-ForeignHeldPaths`, so from this
landing its commit holds a deletion that was present at start, with no change to capture-run.

**The live case that exists now.** Before noon on 2026-09-23 `git --no-optional-locks status` in the main checkout
showed one worktree deletion, ` D grocery/out/browser-capture-due-2026-09-21.flag`. HEAD tracks it (added by the
`[daily]` commit 5d842a7f8 on 2026-09-21), and it sits under `grocery/out`, one of the owned paths capture-run
snapshots at start (`Get-BotInputPaths` plus `Get-BotServedPaths`).

**Bar, deterministic: 0.** The count is `[daily]` commits that delete a path which was already a worktree deletion
when their run started.
- **2026-09-24**, after TC Grocery Ad Pulls 0700 and TC Grocery Daily Capture 0800: if the flag is still absent when
  a run starts, that run's `[daily]` commit carries no `D` for it (`git show --name-status <commit>`), `git ls-tree
  origin/main -- grocery/out/browser-capture-due-2026-09-21.flag` still lists it, and the run's log names it on the
  existing `foreign-held:` line. If a person commits or restores the flag first, the case is void: say so and give no
  verdict for that day.
- **2026-10-07**, 14 days after landing, section 8's default window: every `[daily]` commit from 2026-09-24 on. For
  each `D` entry whose path that run's status record lists in `dirty_at_start`, read by hand whether the run deleted
  a file it was handed modified (legal, the run's own) or a file already absent at start (a defect). Report N, the
  commits read. The status record does not store an entry's kind, which is why this half is read rather than counted.

**The known residual is expected, not a failure** (plan section 10): a held deletion is named on every run until a
person commits or restores the file. A visible leak, never a lost file.

## w0.2 still owes its capture-run line and its size-gate deletion cases, in files another lane owns

`OPEN` `queue-7` `2-WAY` `RUNG1 BUILD`

**What landed and what did not.** W0.2 names three files. Only `lib/pipeline-commit.ps1` landed, because the sh-pc
lane did not own the other two. Its "Done when" (both suites exit 0 with their verdict lines) holds, but two of its
steps do not:
- **Step 3, `grocery/capture-run.ps1`.** The FOREIGN-HELD BLOCK does not yet print
  `foreign-held: kept a deletion present at start: <path>`. The lib builds that line in
  `Format-ForeignHeldDeletionLines`, and `Invoke-PipelineCommit` prints it for the lanes that commit through it.
  capture-run holds the deletion today and names it only inside its count line, and its status record lists the path
  in `dirty_at_start` without its kind.
- **`grocery/test-commit-size-gate.ps1`, its third lifted block.** It has no deletion case. Its 24 cases keep their
  verdicts (exit 0, `cases=24 failed=0`, run twice at landing), which is W0.2's CLEAN TWIN and nothing more.

**First rung.** The next lane of the same plan to edit these files takes it: W2.2 edits both, and W4.1 and W4.2 edit
capture-run. capture-run's FOREIGN-HELD BLOCK prints the line through `Format-ForeignHeldDeletionLines`, and
`dirty_at_start` gains each entry's `kind`. Then the size gate gains the
plan's MUST FIRE (an owned tracked file deleted before the run and still absent is not committed, and the line is
printed) and its MUST NOT FIRE (a file deleted during the run is committed as a deletion), and asserts its new count.
