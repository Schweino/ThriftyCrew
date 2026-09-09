# Pre-registration: does setting a price alert predict retention?

**Status: PRE-REGISTERED, NOT RUN. Written 2026-09-09 for backlog I99, before any retention data
exists.** Ruled by Brad 2026-09-09: pre-register it and snapshot the counts monthly.

**Harness and commit** (per `.claude/rules/measurement.md`): the snapshot producer is
`ops/member-cohorts.ps1 -AppendHistory`, run from `grocery/capture-watchdog.ps1` check 5a4. The series
this analysis will read is `ops/member-alert-history.jsonl`. The commit that introduced both is the one
carrying this file. Anything that reads the series later states the commit it read at.

## Why this document exists before the data

`growth-craft/cohort-retention.md` 6 calls an early voluntary action an aha-moment candidate. The
temptation it creates is specific and this estate already has a rule against it: **choosing the split
that produces the biggest gap is selection on noise.** So the window, the cut and the bar are fixed
here, above the data, and a later analysis that changes any of them is a different study and says so.

## The correction that changes the design

Backlog I99 as filed describes the label as *"a per-member, timestamped-by-label opt-in action"*.
**That is wrong in a way that matters. A Ghost label carries no per-member timestamp** - the member
either has `alert-<id>` now or does not. So *"set an alert within 30 days of signup"* **cannot be
recovered retrospectively at all**, from any pull, ever.

It becomes measurable only going forward, and only because the monthly series exists: a member's signup
month is known, so the first snapshot in which their cohort's alert count rises bounds when the alert
appeared. **The resolution is therefore one month, not 30 days**, and the exposure definition below is
written in the units the data can actually carry rather than the units the item wished for.

## The design, fixed now

- **Population.** Members whose signup month is at least two snapshots old, so every member has had a
  full observation month.
- **Exposure (arm A).** A cohort's alert-bearing count is non-zero **in the first snapshot taken after
  the signup month**. Arm B is the complement.
- **Outcome.** Share of that signup cohort still carrying a paying status at the snapshot **six months**
  after signup.
- **The cut is `>= 1` alert. It is not tunable.** Not `>= 2`, not "top quartile of alerts". One is the
  only cut that needs no justification from the data itself.

## The acceptance bar, in the metric's own units

**The test does not run until both arms have at least 91 members**, and this is the number that
matters most in this document.

Two-proportion comparison, alpha 0.05 two-sided, power 0.80, detecting 50% against 30% retention:

    n per arm  =  (1.96 + 0.84)^2 x (0.5x0.5 + 0.3x0.7) / (0.5 - 0.3)^2
               =  7.84 x 0.46 / 0.04
               =  91

**Today the whole membership is 18 and 4 of them pay.** So the honest statement is not "the effect is
small" or "there is no effect" - it is that **this question is unanswerable now and will stay
unanswerable for a long time**, and the reason to run the snapshot anyway is that the signal decays if
nobody records it.

- If both arms reach 91 and the gap clears 20 points, the alert prompt is a retention lever worth
  building into onboarding.
- If both arms reach 91 and the gap does not clear 20 points, **that is a real answer and it is
  published as one**, not quietly dropped.
- Below 91 per arm, the only permitted output is the counts **with their denominators** and the words
  "not answerable yet".

## What would invalidate it

- **Confounding is the obvious risk and it is not controlled.** A member who sets an alert is plausibly
  more engaged already, so a gap would establish association and not cause. Naming that here means a
  later reader cannot mistake one for the other; the estate has paid twice for exactly that confusion
  (`grocery/check-ad-cycles.ps1`, `design/EVAL-hunter-wall-clock-2026-09-04.md`).
- If the Worker's `POST /alert` ever stops writing the label, or the label naming changes, the exposure
  arm silently becomes everybody-in-B. `grocery/send-price-alerts.ps1:99` is the only other reader of
  that naming and both must move together.
- If a label is ever removed from a member, the series records the fall but not the removal, and the
  arm assignment above uses the FIRST post-signup snapshot precisely so a later removal cannot
  retroactively move anyone between arms.

## The privacy boundary

Identical to the one Brad ruled for I97 and I98: **aggregate counts only, no member row, no id, no
address, and no label string.** What is derived per member is a single integer - how many alert labels
they carry - and it is aggregated immediately and never written. The series can hold only month
strings, status strings and integers.
