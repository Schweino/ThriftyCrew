# PLAN — Graduating `graph/` from bystander to something that earns its keep

**Status: for Brad, 2026-08-21.** He said: *"I think Im confident to graduate this system and well work out the 'kinks' as it's live. We dont have a ton of traffic yet."* This plan takes that as the decision and asks only **which job it graduates into**, because that choice changes the risk by an order of magnitude.

Every number here was measured on 2026-08-21, not assumed.

---

## 1. What `graph/` actually is, in plain terms

The PowerShell system does the work: it pulls prices, ranks them, builds the board, publishes the page. That is the whole business.

`graph/` is a **second brain over the same facts**. It reads what the PowerShell system already knows — 7 stores, 673 commodities, 3,388 product SKUs, 26,740 price observations, the known-wrong rulings, the category guardrails — and stores them as a network of connections rather than as files. It is written in Python (3.12.10, at `C:\Codex\Python312`).

Today it is a **bystander**. It reads everything and writes only to itself. Nothing on the website touches it, no scheduled task runs it, and if it were deleted tomorrow the board would publish exactly as it does now.

It refreshes from the live estate in **1 second**.

---

## 2. What "graduate" could mean — three very different jobs

Graduating is not one switch. There are three jobs it could take, and they carry wildly different risk.

### Level 1 — let it CHECK the board (recommended)
It already runs seven integrity checks and today **all seven pass**:

```
PASS  omaha_identity          PASS  ad_reversion_owed
PASS  ad_window               PASS  provenance_complete
PASS  known_wrong_not_priced  PASS  row_age
PASS  no_unresolved_pricing
```

In this job graph never decides a price. It looks at the finished board and says "this looks wrong" or stays quiet. **The worst it can do is complain.** It cannot invent a cell, move a crown, or change a number.

It has already earned this once: on its first run it flagged that Fareway's weekly ad window had expired 2026-08-15 while `next_pull` said 2026-08-16.

### Level 2 — let it decide product IDENTITY
This is the hard question: is *"Great Value Long Grain Rice, 20 lb"* the same thing as the commodity `rice`? Get it right and coverage improves. Get it wrong and two different products get treated as one, which is a **wrong price on the board**.

This is where its one failing number lives, and it is worth reading carefully:

| measure | value | gate | verdict |
|---|---|---|---|
| false-merge | **0.0000** | ≤ 0.02 | **PASS** |
| missed-merge | **0.3590** | ≤ 0.10 | **FAIL**, by 3.6× |

Translated: graph **never wrongly merges two different products** — that number is a clean zero. What it does is *miss* about 36% of the merges it should make.

Those fail in opposite directions. A missed merge means a commodity simply doesn't get a cell — a coverage gap, which the PowerShell system still fills. A false merge means a wrong price. **The dangerous direction is at zero; the failing one is the safe direction.** That genuinely supports Brad's instinct.

Caveat, stated plainly: that eval was run **deterministic-only** — the model-assisted lane was excluded, and the notes already record that lane as held for being too noisy. So 0.641 recall is the floor of what it can do, not the ceiling.

### Level 3 — let it hold the price state
Replace the price table with graph's own. **Not recommended, and not needed** — the wide price table shipped today, is live, is guarded, and reconciles 3,022 of 3,022 cells against the published board every build. There is nothing here to win.

---

## 3. Recommendation

**Graduate Level 1 now. Hold Level 2 until the missed-merge number moves. Drop Level 3.**

The reasoning is short: Level 1 is ready today on its own numbers, cannot produce a wrong price by construction, and starts paying immediately. Level 2's gate is failing by 3.6× and there is no reason to accept that when the PowerShell matcher already covers the job.

"Work out the kinks live" is a good instinct for a checker. It is a bad instinct for a matcher, because a matcher's kinks are wrong prices and this estate has spent the whole day proving that wrong prices are found by luck, not by guards.

---

## 4. The one real risk, and it already bit us today

`graph/` reads some of its rules **out of the PowerShell system's source code** — literally grepping the text of `capture-policy.ps1` for `$script:MaxCarryDays`.

That broke this morning. `capture-policy.ps1` was split (its `param()` block was clobbering caller variables), `MaxCarryDays` moved to the new library file, and graph's `row_age` gate went red with *"cannot find `$script:MaxCarryDays`"*. Nothing in the PowerShell tree can know that reader exists, so a perfectly reasonable change over there silently broke a gate over here.

It behaved correctly — it refused to guess and failed loudly — and it is fixed. But note what it means: **graph is coupled to the other system's file layout, not just to its values.**

That is fine while graph is a bystander. It is not fine if graph can block publishing.

**Therefore, precondition for Level 1:** graph's verdict must be **advisory on arrival**. If graph errors, cannot run, or cannot find a rule, the board publishes anyway and the failure goes to the alert queue. Only after it has run clean alongside the live chain for a couple of weeks should it be allowed to actually block a publish — and even then only on the gates that have never produced a false alarm.

The reason is the one this estate keeps re-learning: a new gate's first red is usually the gate.

---

## 5. Concrete steps

1. **Add a refresh + check step to the daily chain, advisory.** `import_all.py` then the seven gates; 1 second plus the check. Output goes to the log and to the alert queue, and cannot fail the build.
2. **Watch it for two weeks.** The question is not "does it pass" — it passes today — but "does it ever fire when the board is actually fine?" A gate that cries wolf once is worse than no gate.
3. **Promote to blocking, gate by gate.** Only the ones with a clean two-week record.
4. **Leave Level 2 alone** until someone deliberately works the missed-merge number, with the model lane evaluated rather than assumed.

Steps 1–3 are small. Step 4 is a real project and should be scheduled as one, not slipped in.

---

## 6. What this does NOT decide

Whether `graph/` is worth keeping *at all* is a separate question, and an honest one — it is a second implementation of facts the PowerShell estate already owns, and the V3/V4 platform estate was deleted on 2026-08-14 for being exactly that shape. Level 1 is the cheapest possible way to find out whether it earns its place: give it the job it is already good at, and see whether it catches anything the existing guards miss over a month.

If it does, graduate further. If it catches nothing in a month, that is an answer too.
