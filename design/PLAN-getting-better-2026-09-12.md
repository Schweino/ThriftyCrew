# How this estate gets better at engineering, end to end

2026-09-12. Written after a day of measuring the learning system rather than adding to it.
Every number here was measured today and the scripts are named; nothing is an impression.

## The finding that sets the agenda

**The repeat-failure rate is 34% and FLAT.**

| | |
|---|---|
| real failures recorded (our own guard denials excluded) | 1,496 |
| distinct failure signatures | 985 |
| repeat rate | **34%** |

Share of each day's failures already seen on an EARLIER day, over twelve days:
`18 · 11 · 25 · 28 · 20 · 22 · 12 · 29 · 26 · 17 · 28` percent. No slope.

So: 174 memories, 29 reflex rows, 45 gates, and a quarter of what breaks each day is
something that already broke before. **We are accumulating knowledge and not converting it
into fewer failures.** That is the problem this plan exists to fix, and the repeat rate is
the number that says whether any of it worked.

## Why it is flat, and it is not lack of effort

The most-repeated real failures are:

```
 44  FileNotFoundError: [Errno <n>] No such file or directory
 29  SyntaxError: unterminated string literal
 29  Remove-Item on system path is blocked
 27  unexpected EOF while looking for matching '
 10  AttributeError: object has no attribute
```

Paths, quoting, shell escaping. Boring, mechanical, frequent.

The 174 memories are about namespaced commodity ids, band censorship, paywall direction,
gate-slot arrival order. Subtle, hard-won, and mostly **once in a lifetime**.

**We have been mining our most interesting failures and ignoring our most frequent ones.**
Not wrong as in false; wrong as in rare. A lesson that fires once prevents one failure.

## The plan

### Phase 0 - make the steering signal trustworthy (cheap, do first)

The repeat rate is only as good as the log under it, and the log is roughly 15% noise:
192 rows are our OWN reflex denials recorded as failures (98% repeat by construction - the
same instrument defect fixed in the outcome scorer this morning, in a second place), plus
bare `EXIT=<n>` lines and `## main...origin/main` git output classified as errors.

1. Classify those out at write time, not at read time.
2. Record the repeat rate weekly so there is a SERIES, not today's snapshot.

**Done when:** the weekly number exists and excludes our own output. No behaviour change.

### Phase 1 - attack the FREQUENT, not the interesting (the largest measured win)

Take the top 20 repeated real signatures and, for each, ask the only question that matters:
could a recogniser have prevented it? Write the row where the answer is yes - pattern, both
fixture sets, scope, cap - through the contract that already exists.

That is roughly **200 preventable failures a month** with no recogniser today, because
nobody has ever mined the failure log by frequency.

**Done when:** the top 20 each have a row or a written reason they cannot have one.
**Measured by:** the repeat rate, weekly, against today's 34%.

### Phase 2 - close the loop so it runs without a session deciding

Today's promotion was done by hand and took an afternoon; the funnel records
`promoted_by_use: 0` before it. Every part exists - failures logged, drafts mined, evidence
scored, fixtures enforced. The circuit has simply never closed by itself.

1. Promote automatically when a draft clears a stated bar: recurs N times across M sessions,
   both fixture sets present, scope checked against its own must_fire, rung `remind` only.
2. Backfill `authored.failures_matched` on the ~47 drafts mined in a later batch that carry
   none, so they can be ranked at all.
3. Fix the Edit/Write scoring blind spot, or record that rows firing only on edits can never
   auto-promote. Today: `cmdletbinding-empties-psscriptroot` has fired 165 times and resolved
   0, because Edit and Write report no exit code.

**Done when:** a new recogniser can reach `remind` with no human in the loop.

### Phase 3 - retire, or the table rots

`--rate` already fails on two live rows that have outgrown their caps: `ps-array-wrap-call`
at 3.55% over 3%, `count-on-maybe-absent` at 5.78% over 4%. The retirement rule exists
(`MIN_OFFERS 5` AND `MIN_SESSIONS 3`, never opened) and has never been applied to anything.
A table that only grows becomes noise, and noise is how a tier teaches people to ignore it -
which is exactly how 22 store sections went dead unnoticed.

**Done when:** both over-cap rows are tightened (not re-capped), and retirement runs on a
schedule rather than on somebody noticing.

### Phase 4 - the half gates cannot reach

`software-craft/packaging-and-tooling.md` 6 states the ceiling plainly: *automated checks
are for rules that are objective and repeatable; humans are for design decisions, business
requirements and architectural trade-offs.* No number of recognisers improves DESIGN.

Two levers remain, and both are slower:

- **Exemplars.** `CLAUDE.md` already says existing code is an instruction nobody wrote on
  purpose, and that if output keeps coming out wrong the same way you should find the file
  it is imitating. The converse is the lever: make the best file the most-imitated one. New
  code inherits the quality of what it copied, which compounds silently.
- **Review at a boundary**, for the judgement half - not per edit, which was measured and
  refused today.

## What NOT to do, each refused on evidence today

- **Do not build more retrieval.** Two signals for automatic craft recall at edit time were
  measured and refused (the file path, 10 of 20; the code written, 4 of 20), for one shared
  cause: our code speaks estate vocabulary and the craft speaks craft vocabulary, and
  similarity cannot bridge them. The third candidate is predicted to fail for the same reason.
- **Do not add prose rules.** Measured: 10% of the 174 memories act. A rule in a file was
  broken today by a reader who had opened that file minutes earlier; the gate caught it.
- **Do not promote on burn rate.** A low burn means the command usually SUCCEEDED. Ranking on
  it produced an almost entirely different - and wrong - set from ranking on real failures.

## The honest target

Exponential is not available. Repeat rate is bounded, and what compounds is second-order:
failures we stop having are hours we stop spending, and those hours go into improvement.

**The falsifiable one-month target: the repeat rate falls meaningfully from 34%, measured
weekly, with the noise removed first.** If it does not move, Phase 1 was the wrong bet and
this document should say so rather than be quietly dropped.
