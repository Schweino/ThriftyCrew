# W0: what the 49 always-run push checks have actually caught (2026-09-27)

Plan: `design/PLAN-push-gate-diet-2026-09-27.md` W0. Evidence for Brad's ruling on D3 (which checks, if any, move to
nightly only). No gate was changed. Row data: `design/W0-gate-catches-2026-09-27.tsv`, one row per check.

## Answer

**7 of 49 checks have a verified real catch on a push that was not their own.** Those 7 cost 72.5 s of run C's
256.7 s. The other 42 cost 184.2 s and show no catch in the record read.

The recommendation is **not** to move those 42 to nightly. 32 of the 49 are self-tests, and a self-test's verdict on
a data-only push can only change if it reads live data. For almost all of them the right move is to key them, so
they skip data-only pushes and still run on every code push that could break them. Only audit-secrets and six
cheap ambient checks stay unkeyed.

**Expected data-only push if every recommendation is accepted: about 66 s.** That is 30.0 s of checks left unkeyed
plus the 36 s of keyed jobs that correctly re-ran in run C. It is ONE run per arm (run C), so it is a direction, not
a median, and it assumes every "cheaper" item keys successfully.

## Where the numbers come from

- **The 49 jobs** are the `state: unkeyable` rows of run C, `48976@2026-09-27T14:07:29.4227792Z`, in the gate-times
  file for 2026-09-27 that `ops/run-gates.ps1` writes under `%LOCALAPPDATA%\ThriftyCrew\gate-times\`. They total
  256.7 s, matching the plan's 257 s.
- **Median seconds** are over every executed row for each job from 2026-09-25 to 09-27: 145 executions for most jobs,
  35 to 50 for the five that became unkeyable recently.
- **Reds in those rows:** only 6 of the 49 ever returned nonzero in the 145 runs: conclusion-currency 16,
  stray-root-artifacts 13, always-loaded-bytes 4, measurement-provenance 2, sale-fallback self-test 1,
  prompt-backup 1. A red is not a catch; each was traced.
- **Catches** come from reading commit messages on origin/main. The leads were commits naming each check near
  red/refused/caught words: about 590 leads over 47 basenames, read by four helpers and checked by hand.
  **A catch counts only when a real change was refused or fixed because of that job.** A check's own introducing or
  extending commit does not count, nor does a change proving its own new fixture red then green.
- **Spot-checked by me:** 748967ad4, 98c3f060a, 1f7643b7a, bda9e5e0d, d8ba6d944, 7f7af2e99, 4e8102c21. Each says in
  its own message that the named check refused or failed it.
- **The push ledger** (`push-ledger\pushes-*.jsonl`) records `refused-gate-red` but never names the gate, so it
  could not count catches on its own.
- **Limit of the method:** a fix made silently inside a larger commit, with no words about it, cannot be seen this
  way. No refusal was reproduced.

## The 7 checks with a real catch

| Check | Run C s | Catches | Evidence |
|---|---|---|---|
| prepush-test-auditors -SelfTest | 45.0 | 1 | 748967ad4: a reporter rename made 4 of 88 must-fires red; fixed before landing |
| audit-conclusion-currency | 21.7 | 23 refusals | e.g. 73a59ee72, 663e2dd5c, c11c080f2. **0 of 23 re-reads found a changed conclusion**; 5 caught citation mechanics (a rebased hash) |
| audit-prompt-backup | 1.8 | 8 | d8ba6d944, 6621324d3, fc55f4f29, 3c363cba9, a6a7714fc, 9a2a80b2e, d169f5ba7, 0eefa0ff4: a prompt changed without its mirror |
| audit-always-loaded-bytes | 0.9 | 3 | 1f7643b7a (push refused), bcf5b3f8b, bda9e5e0d (+683 B cut to +246 B) |
| audit-task-registration | 1.3 | 1 | 7f7af2e99: a watched task with no committed definition |
| audit-stray-root-artifacts | 1.2 | 1 | 4e8102c21: `.worktreeinclude` untracked at the root |
| audit-measurement-provenance | 0.6 | 1 | 98c3f060a: ratchet 8 to 9 on a bullet-form marker |

**Borderline, not counted:** audit-run-log-claims, 88c7a835c. The red came from the main checkout lagging behind,
not from a defect in the change.

**Catches that belong to a different job**, not one of the 49, and so not counted:
- audit-store-registry's static run: 2dcd09aff, 641fb5288, 8eb56de7f.
- audit-source-comment-strip's static run: c02f11eac, b1aa4dfff.
- audit-guard-contract's live run: e62f9c130, 30444c2c0 and five more.
- audit-fixture-inputs' live audit: 478ce8b0e, a2307af0b and three more.
- prepush-test-auditors' live hook leg: about 13 refusals, e.g. cbbe61b42 and a9d1f1691.

These are evidence that those scripts earn their place, but through a job not being ruled on here.

## Why the 42 zero-catch checks unkey instead of moving

Every run C job is unkeyable for one of five reasons (the `why` column of the gate-times rows):

| Reason | Jobs | Run C s | Cheaper at push |
|---|---|---|---|
| A comment example at `lib/selftest-lib.ps1:269` names `push-main\selftest.ps1`, which the key reads as a real file | 5 | 18.7 | Rephrase or skip comment text in the key. One line, and it makes 5 self-tests keyable (new today with the file-split work) |
| Python self-test with no `# gate-inputs:` line | 8 | 32.8 | Declare inputs. 68 Python files already do |
| Static detector with no declared scan set | 17 | 59.6 | Declare a scan set, as round 3 did for 11 detectors, except the ambient ones kept below |
| Reads a data directory (`grocery\out`, `.git`) | 12 | 64.1 | Point fixtures at a temp copy, then declare inputs. If that is not possible, nightly |
| Builds a path the key cannot parse | 7 | 81.5 | Declare inputs, or teach the key the nested Join-Path spelling |

**Keying beats nightly for a zero-catch self-test.** Nightly leaves a code change unchecked for up to a day and
skips every data-only push. Keying keeps every code push checked and still skips every data-only push. The cost is
a declaration, and the declaration can go wrong: `-VerifyDeclared` exists for that (og-45).

## Stays unkeyed on push (30.0 s)

- **audit-secrets static, 19.0 s.** 0 catches, but it reads the push's own commits, and a secret that reaches GitHub
  cannot be taken back. Keep, whatever the cost.
- **Cheap ambient checks, 11.0 s together:**
  - prompt-backup 1.8 s
  - task-registry 1.4 s
  - task-registration 1.3 s
  - stray-root-artifacts 1.2 s
  - event-bus 1.1 s
  - memory-citations 1.1 s
  - always-loaded-bytes 0.9 s
  - run-log-claims 0.8 s
  - drain-staged 0.8 s
  - measurement-provenance 0.6 s

  They read machine state or files a source key cannot watch, and together they hold 5 of the 7 checks with catches.

## Decisions for Brad

1. **D3: move no check to nightly now.** Recommended. Unkey the 42 instead, with the options in the TSV's
   `cheaper_at_push` column. Expected data-only push about 66 s, under the 150 s bar, on one run.
2. **Fallback to nightly** only for the 8 rows marked "cheaper (else nightly)" if their fixtures cannot stop
   reading live data. Their catches are 0 and their risk is one store's rows or one weekly send for a day. Three
   rows, send-price-alerts, ghost-drift and monitor-live-recipe-prices, are marked "else keep" instead, because they
   touch member email, the paid site and live recipe prices.
3. **audit-conclusion-currency: key it, do not move it.** 23 refusals and 0 changed conclusions, but a data-only push
   cannot move a harness. Key on the tracked code, design docs and `design/reread-ledger.tsv`, which saves 21.7 s on
   data pushes and keeps it whole on code pushes.
4. **prepush-test-auditors self-test: key it.** It is 45 s, the largest single job, and it has 1 real catch.
   Declaring its inputs keeps the catch and saves the 45 s on data pushes.
5. **audit-secrets: keep, unkeyed.**

## Open

- The empty `recall-sleep.py` untracked at the main checkout's root keeps audit-stray-root-artifacts red there, and
  no one has named what writes it. The coordinator is handling it; this lane did not touch it.
- None of the "cheaper" items is built or measured. The 66 s is a projection from run C's rows, not a measurement.
