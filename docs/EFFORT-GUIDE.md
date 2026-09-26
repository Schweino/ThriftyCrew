# Spending effort

Source: Thariq (@trq212), "Using Claude Code: Spending your effort", 2026-09-25,
https://x.com/trq212/status/2103576349499855160 (full version with diagrams:
https://claude.dev/blog/spending-your-effort/). Brad pasted the post's text on 2026-09-26. The figures below are
the author's own eval runs, not measured here.

## What effort is

Effort tells the model how much compute to spend on a task. Every level does the task reasonably. Higher effort
buys **more verification, more edge-case testing and more independent judgement**, and with that judgement comes
more assumptions made on your behalf. Changing effort mid-conversation (`/effort`) does not break the prompt
cache on the current models.

## What it buys, and what it does not

- **It fixes missing edge cases. It does not fix a wrong approach.** Across Terminal-Bench 3.0, raising effort
  cut the failures from missed edge cases, while the failures from a wrong approach stayed. If the plan is wrong,
  more effort only verifies the wrong thing more carefully. Fix the plan: interview, spec, or triage-reviewer.
- **Where it pays:** tasks with many hidden edge cases, high production stakes, or no human in the loop (security,
  hardware, code review, perf, bug fixes in brownfield code). Examples from the post, all at author scale:
  - HTML sanitizer: 1/5 at low vs 5/5 at xhigh. Low wrote one pass and tested one page, in about 2 minutes.
    High adversarially reviewed its draft, read the parser source, ran an XSS suite and wrote a fuzzer, in
    about 33 minutes.
  - Storage-engine crash fix: 0/5 at low vs 4/5 at xhigh. Low edited code before reproducing the crash. High
    reproduced it first, tested against a reference, and checked that its tests failed on half-finished fixes.
  - Data analysis: 0/5 at low vs 4/5 at high. High tried two data preps, saw the answer change, and found out
    why. With a human in the loop, a low-effort run could have just asked.
- **Where it doesn't:** a well-specified task. Given a detailed interview spec, every level built much the same
  thing. On an underspecified task, higher effort builds more but decides more for you.

## Rule of thumb

| Level | Use for |
|---|---|
| low | fast and in the loop: brainstorming, sketching, easy changes, iterating on feedback |
| medium | most ordinary engineering and implementing a clear spec |
| high | verification matters or edge cases are hidden: brownfield bug fixes, review, audits |
| max / xhigh | fully autonomous hard problems: end-to-end build and verify, security review of critical code |

The loop the author recommends for feature work:
1. Give a spec and have Claude interview you for what is missing.
2. Implement on low or medium.
3. Review the gist yourself and iterate at low.
4. Verify and test on high.

## How this maps onto this estate

This estate already runs the loop above: **depth goes into planning and verification, and implementation runs
at medium.** The triage-reviewer is high and read-only, the triage developers are medium (Brad, 2026-09-22), and
the batch auditor and post-publish reviewer, both verifiers, are high. Two consequences follow:

- **Money-path verification stays high.** A wrong number on a live, paid page is exactly the "hidden edge case,
  no human in the loop" case the post says effort pays for. The reviewers, auditors and adversarial checks
  belong at high or above.
- **Raising an implementer's effort is the wrong fix for a wrong plan.** When a medium developer fails because the
  plan was wrong, the repair goes to the plan (the reviewer), not the developer's effort level.

Ruled by Brad, 2026-09-26: `recipe-sourcer` moves from `high` to `medium`. Its output is candidates that the
dedup-selector, extractor, mapper and batch auditor all re-check, so a sourcing miss costs a later stage time,
never a wrong number on a page. It stays above `low` because it runs with no human in the loop and its catalog
dedup and fit filters (board-priced ingredients, no seafood) are edge-case work; `low` would need a measured
paired run first (start medium, lower only on measured evidence).
