---
description: Rules for published copy and delivery - Ghost, the feed, the worker, and anything a reader sees.
globs: "site/**, content/**, public/**, worker/**"
alwaysApply: false
---

> **Resolving the `[[citations]]` below.** Each is a filename without its extension, under
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/`. So `[[propagate-has-no-slugs]]` is
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/propagate-has-no-slugs.md`. The line here is a
> pointer; the file is the account. Read it before acting on the pointer, and never write to that
> directory - it is outside the repo and outside your worktree.


# Working in `site/`, `content/`, `public/` or `worker/`

Loaded only when you touch something a reader sees. This is a LIVE, PAID site: a wrong number here is a
real cost to a real person, and understating is exactly as wrong as overstating.

- **Any page whose layout changed gets the 375px mobile check.** No horizontal scroll, nothing crushed.
  And a measurement is not a look - screenshot the element you changed and read the words.
  [[a-measurement-is-not-a-look]]
- **`public/board.json` carries structured `__rows`, and committing that file IS the feed deploy.** It
  ships BEFORE the post. [[board-json-carries-structured-rows]]
- **`build-deals-page` clobbers `public/` artifacts** - restore `public/` from git after any local
  build. [[build-deals-page-clobbers-public-artifacts]]
- **A Ghost 422 is a field length**, and `custom_excerpt` is 300 chars AFTER token expansion.
  [[ghost-422-is-a-field-length]]
- **Check the paywall in the direction that loses money.** Every visibility guard here once checked
  only the cosmetic direction, and 22 paid recipes were served free.
  [[paywall-leak-direction-unwatched]]
- **Ghost integration tokens 403 on `/settings/` writes and all `/stats/`** - those need the browser.
  [[ghost-integration-token-limits]]
- **Content workbooks are FORMULA-DRIVEN.** `content/workbooks/` carries 28,821 live formula cells; a
  values-only regeneration opens fine, looks right and is inert. [[workbooks-are-formula-driven]]

Regime: this holds for reader-facing output. Internal data files under `grocery/` and `meal-prep/` have
their own rules files.
