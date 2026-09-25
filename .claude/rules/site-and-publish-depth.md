---
description: DEPTH for site-and-publish.md: the full account behind each one-line publishing rule.
paths:
  - "site/**"
  - "content/**"
  - "public/**"
  - "worker/**"
  - "meal-prep/**"
  - ".claude/skills/lesson/**"
  - "lib/ghost-lib.ps1"
  - "grocery/build-deals-page.ps1"
  - "grocery/send-*"
  - "**/*publish*.ps1"
---

> **Resolving the `[[citations]]` below.** Each is a filename without its extension, under
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/`. So `[[propagate-has-no-slugs]]` is
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/propagate-has-no-slugs.md`. The line here is a
> pointer; the file is the account. Read it before acting on the pointer, and never write to that
> directory - it is outside the repo and outside your worktree.


# Working in `site/`, `content/`, `public/` or `worker/`

DEPTH FILE (option B, design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md W2.3 D2): it loads
only after a session READS a file matching its `paths:` key, never at session start and never from an
Edit, a Write or a shell command alone. One line per rule is in `.claude/rules/site-and-publish.md`, which loads in
every session. Apart from this sentence and the front matter, this file is the option-A file verbatim. This is a LIVE, PAID site: a
wrong number here is a real cost to a real person, and understating is exactly as wrong as overstating.

- **Any page whose layout changed gets the 375px mobile check.** No horizontal scroll, nothing crushed.
  And a measurement is not a look - screenshot the element you changed and read the words.
  [[a-measurement-is-not-a-look]]
- **`public/board.json` carries structured `__rows`, and committing that file IS the feed deploy.** It
  ships BEFORE the post. [[board-json-carries-structured-rows]]
- **`build-deals-page` clobbers `public/` artifacts** - restore `public/` from git after any local
  build. [[build-deals-page-clobbers-public-artifacts]]
- **A RECIPE POST CARRIES NO PRICE LITERAL; EVERY PRICE RENDERS FROM THE FEED AT VIEW TIME** (Brad's instruction,
  2026-09-21: *"If a pricing updates in the DB its automatically updated on all recipe pages."*). So a price move
  never needs a republish. `meal-prep/engine/publish.ps1` refuses a card with a money figure outside a stamped live
  placeholder (`meal-prep/lib/price-literal-gate.ps1`; allowed literals: exactly `$1 a month` and `$10 a year`), the feed
  contract (`meal-prep/pipeline/audit-live-price-contract.ps1`) fails a placeholder the feed cannot fill, and the
  daily live monitor (`meal-prep/pipeline/monitor-live-recipe-prices.ps1`) runs each live post's own script against
  the deployed feed and pages on a mismatch, a missing script or a missing feed. **Site-wide code injection is out of
  its reach**: the homepage's "Fourteen servings at about $2.40 each" quote lives there, frozen, and is a ruling for
  Brad. Full account in `.claude/rules/meal-prep.md` and `design/PLAN-live-recipe-prices-2026-09-21.md`.
- **A Ghost 422 is a field length**, and `custom_excerpt` is 300 chars AFTER token expansion.
  [[ghost-422-is-a-field-length]]
- **Check the paywall in the direction that loses money.** Every visibility guard here once checked
  only the cosmetic direction, and 22 paid recipes were served free.
  [[paywall-leak-direction-unwatched]]
- **Ghost integration tokens 403 on `/settings/` writes and all `/stats/`** - those need the browser.
  [[ghost-integration-token-limits]]
- **Content workbooks are FORMULA-DRIVEN.** `content/workbooks/` carries 28,821 live formula cells; a
  values-only regeneration opens fine, looks right and is inert. [[workbooks-are-formula-driven]]
- **A RATE OF RETURN IN A LESSON CARRIES FOUR THINGS NEXT TO THE NUMBER** (Brad's ruling, 2026-09-12,
  backlog I112). Verbatim: *"A lesson may show a projected rate of return only when it carries, next to
  the number: the source and the period it covers, whether it is nominal or after inflation, and that fees
  are not included (or the fee assumed). Prefer a historical figure stated as history over a forward
  projection, and pair any nominal figure with its after-inflation figure. No rate may be lifted from a
  course or chart that does not name its source. Illustrations that are pure arithmetic (penny doubling, a
  stated made-up rate labelled as an example) are fine and need none of this. Existing lessons that quote
  a rate get checked against this rule the next time they are edited."* **A HEDGE is not a LABEL**: *"past
  returns don't guarantee future results"* sources nothing, while *"let's say 7%"* exempts the number
  because the lesson invented it. `ops/audit-lesson-rate-claims.ps1` holds it on every push over all
  markdown under `content/`, a ratchet whose mark only falls. Its first run, at the commit that added it,
  read 118 files, 5,271 paragraphs, 14 rate-of-return claims, 8 labelled illustrations, 0 fully qualified
  and 6 unqualified; those six are the worklist it prints, fixed when each is next edited. The detector is
  unsound (it finds the spellings it knows, and a rate reaching Ghost by another road is outside it), so
  this line is the half that reaches the writer before the prose exists. The drafting step is `Step 1` of
  `.claude/skills/lesson/SKILL.md`.

Regime: this holds for reader-facing output. Internal data files under `grocery/` and `meal-prep/` have
their own rules files.
