# E1: a safety layer for irreversible writes - the brief, and two designs to compare

2026-09-06. Backlog E1, the biggest item on the list. Built as Best-of-N: two real implementations on
two branches, so the choice is made against running code rather than against my prose about it.

---

## 1. The finding that reshapes the item

The backlog says "Board cells, `known-wrong` rulings, Ghost publishes and R2 writes are all
irreversible from an agent's side." **Three quarters of that is not true, and the part that is true is
the part `post-publish-reviewer` already runs after.**

Every named local target is TRACKED:

| Target | Status |
|---|---|
| `grocery/known-wrong.json` | tracked |
| `grocery/commodities.json` | tracked |
| `meal-prep/db/costed.json` | tracked |
| `public/board.json` | tracked |

**For a tracked file, git already is the undo log.** A wrong ruling written into `known-wrong.json` is
`git checkout --` away while it is uncommitted, and recoverable from history after. Building a second
undo layer over the top of that would be duplicating a mechanism that already works, and worse, it
would be the *visible* mechanism - so the next reader would trust it instead of git.

So the real no-undo surface is narrower and sharper than the entry suggests:

1. **Ghost publishes.** A PUT to the admin API is gone the moment it returns 200. Nothing local can
   reverse it, and a reader may already have seen the page. This is a live paid site.
2. **R2 writes.** Same shape, plus the estate declared in `ops/cloudflare-estate.json` outlives the
   code that was deleted in Aug 2026.
3. **Gitignored local data** - the boards under `grocery/out/`. Not covered by git, and not covered by
   this item either: they are rebuilt daily, so a bad board is corrected by the next build.

**And the timing argument in the backlog is exactly right for the surface that survives.**
`post-publish-reviewer` is the last set of eyes and it runs AFTER the PUT. That is the wrong side of
the only genuinely irreversible thing this estate does.

## 2. The seam, and why this is affordable at all

`lib/ghost-lib.ps1` exports **`Invoke-GhostApi`**, dot-sourced by **29 live scripts**, and it is
already THE resilient HTTP call for every Ghost request in the estate - it exists because ~13 raw
`Invoke-RestMethod` calls had no timeout and hung the daily chain for 25 minutes in July. Both designs
below hook that one function. `meal-prep/engine/publish.ps1` routes 6 calls through it and
`meal-prep/pipeline/wave-publish.ps1` another 4, with no raw `Invoke-RestMethod` in either.

**The local half has NO equivalent seam and this is worth stating loudly**, because it is the trap a
first pass would fall into. `lib/json-io.ps1` looks like the counterpart and is not: it is a READ
consolidation (`Read-JsonFile`, dot-sourced by 209 scripts, written because PS 5.1 decodes a BOM-less
file as ANSI). Its `Write-JsonFile` is **not** universally adopted - `grocery/add-known-wrong.ps1` and
`grocery/set-board-cell.ps1` both call `[IO.File]::WriteAllText` directly, and **271 live scripts write
raw**. A staging layer hooked to `Write-JsonFile` would cover almost nothing while appearing to cover
everything, which is the same reads-right-and-is-inert failure as a values-only workbook regeneration.

## 3. What both designs must do identically

So the comparison is fair and the only variable is the approach:

- hook `Invoke-GhostApi` and nothing else;
- act only on **mutating** methods (PUT, POST, DELETE, PATCH). A GET is a read and always executes
  immediately - reads outnumbering writes is the point, not an accident;
- be **off by default**, so no existing caller changes behaviour until something opts in;
- carry a `-SelfTest` with a must-fire fixture, so `ops/run-gates.ps1` covers it;
- print a words-level verdict and a `<NAME>-COMPLETE` marker (backlog E2, guard contract);
- never require a caller to be edited.

## 4. The two designs

### v1 - STAGING (`e1-staging`). Prevent.

A mutating call does not go out. `Invoke-GhostApi` serialises the intended request - method, uri,
body, and the caller - to a queue, and returns a staged-shaped result. `ops/review-staged.ps1` lists
each queued call, fetches the live resource so the operator sees a real before/after, and applies or
discards. Reads pass through untouched.

The bet: **the problem is usually in the combination, not in any single call.** A review pass can see
that a wave is about to publish eleven posts when the batch was ten; nothing at the level of one call
can.

The cost: **a staged write is not a write.** Any caller that reads back what it just wrote, or branches
on the response, sees something that did not happen. That is a real behavioural change for the publish
chain, and it is the thing to look at hardest when comparing.

### v2 - UNDO LOG (`e1-undo-log`). Recover.

The call executes exactly as it does today. Before a mutating call, the hook GETs the target resource
and journals a **before-image** alongside the request and the response. `ops/revert-ghost-write.ps1`
replays a before-image as a PUT, and the agent may call it itself rather than waiting for a human.

The bet: **an agent that can undo its own mistake recovers in seconds; one that cannot needs a human
who may be asleep.** Autonomy is preserved, and nothing about control flow changes.

The cost: **it recovers, it does not prevent.** The wrong page was live for the interval, and a reader
may have seen it. For a `POST` that creates, the inverse is a delete, which is a different and worse
operation than a restore. And the before-image costs a GET on every write.

## 5. The rubric

Stated up front so the verdict is a judgement and not a preference:

| | Weight | Question |
|---|---|---|
| **Blast radius of adopting it** | high | how many of the 29 callers change behaviour, and does the publish chain still work unmodified |
| **Does it fix E1's actual complaint** | high | is the check on the correct side of the irreversible step |
| **Failure when the layer itself is wrong** | high | what happens if the queue is lost, or the before-image is stale |
| **Autonomy** | medium | can a run recover without a human |
| **Surface area paid on every future change** | medium | how much is there to maintain |
| **Honest about what it cannot do** | medium | does it fail loudly at its own edges |

Both are hooked off by default, so neither can be judged on "it did not break anything" - that is true
of both until switched on. Judge them switched on.
