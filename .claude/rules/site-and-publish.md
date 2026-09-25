---
description: Rules for published copy and delivery - Ghost, the feed, the worker, and anything a reader sees - one line each; the account is site-and-publish-depth.md.
---

# Site and publish rules, one line each

LEAD FILE: loads in every ThriftyCrew session, because it has no `paths:` key, on purpose
(design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md, W2.3 option B, D2). The account behind each line is
`.claude/rules/site-and-publish-depth.md`, which loads only after a session reads a file under `site/`, `content/`,
`public/`, `worker/` or `meal-prep/`, or a publishing script. This is a LIVE, PAID site: understating is exactly as
wrong as overstating. A `[[name]]` is `~/.claude/projects/C--Codex-ThriftyCrew/memory/<name>.md`: read it, never write it.

- Any page whose layout changed gets the 375px mobile check (no horizontal scroll, nothing crushed), and a measurement is not a look: screenshot the element and read the words. [[a-measurement-is-not-a-look]]
- `public/board.json` carries structured `__rows`, and committing that file IS the feed deploy: it ships BEFORE the post. [[board-json-carries-structured-rows]]
- `build-deals-page` clobbers `public/` artifacts: restore `public/` from git after any local build. [[build-deals-page-clobbers-public-artifacts]]
- A recipe post carries no price literal and every price renders from the feed: `meal-prep/engine/publish.ps1` refuses a money figure outside a stamped live placeholder (allowed literals exactly `$1 a month` and `$10 a year`), and site-wide code injection is out of its reach.
- A Ghost 422 is a field length, and `custom_excerpt` is 300 chars AFTER token expansion. [[ghost-422-is-a-field-length]]
- Check the paywall in the direction that LOSES MONEY, not only the cosmetic one. [[paywall-leak-direction-unwatched]]
- Ghost integration tokens 403 on `/settings/` writes and all `/stats/`: those need the browser. [[ghost-integration-token-limits]]
- Content workbooks are FORMULA-DRIVEN: a values-only regeneration opens fine, looks right and is inert. [[workbooks-are-formula-driven]]
- A rate of return in a lesson carries, next to the number, its source and period, nominal or after inflation, and fees (a hedge is not a label; a labelled made-up example is exempt); `ops/audit-lesson-rate-claims.ps1` holds it, and the drafting step is `Step 1` of `.claude/skills/lesson/SKILL.md`.

Regime: this holds for reader-facing output. Internal data files under `grocery/` and `meal-prep/` have their own
rules files.
