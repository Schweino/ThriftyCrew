# PLAN: trim the always-loaded rules without losing a rule, and keep them trimmed (2026-09-25)

## Ruling
Brad, 2026-09-25, asked "Build the best and smartest way that also future proofs us", then chose
**"Trim judgement-safe only"** over a fuller trim: every rule's operative text stays loaded in every session, as his
D2 ruling of the same morning requires (option A kept; option B, one-line leads with path-scoped depth, missed all
three of its bars on `experiment/rules-split-option-b`). What moves out is the history inside each rule:
measurements, dates, incidents, what was tried. Rejected, with the reason: dropping the ~20 gate-enforced rules to
one line would have saved more but made an agent learn those rules from a push refusal instead of before writing.

## Why
`grocery/triage-cost.py --first-call` on the 2026-09-25 triage run: the first time a spawn touches a ThriftyCrew
file it loads CLAUDE.md plus all six rules files, 154,825 characters (+61k to +70k tokens), re-read on every later
call; 9 loads over 8 of 11 spawns, about 1,861,417 of 9,275,890 cost_units. `ops-and-gates.md` was 90,563 of the
154,825, and most of it was history, because each incident added a paragraph and nothing pushed back.

## What was built
1. **`docs/rules-history/ops-and-gates.md`**: the whole file as it stood, byte for byte, with an anchor `og-01` to
   `og-53` before each rule. Nothing loads it.
2. **`.claude/rules/ops-and-gates.md`** rewritten: 53 rules, each its operative text (what to do, what not to do, the
   tool that does it) ending in a tag `(channel: gate <path> | judgement; full: og-NN)`. 18 name the gate that
   enforces them; 35 are judgement, carried only by the text. 90,687 bytes to 21,061.
3. **`ops/audit-rule-format.ps1`**, in `run-gates` on every push, for each file in its manifest (ops-and-gates.md
   today): every rule carries a channel tag; every named gate exists; every rule has its own history anchor; no
   anchor is orphaned (so no rule leaves the loaded file while its account survives only in history); no rule over
   1,100 characters (first plausible bar; the longest rule, the lock order, is 1,004). Self-test 8 of 8.
4. **`ops/out/always-loaded-bytes-baseline.json` tightened** (the W6.6 ratchet): the bytes every ThriftyCrew session
   loads at start went from 155,751 to 86,125, and a rise fails the push.

**How it stays trimmed.** A new rule for a converted file is written as one bullet: the rule, its instruction, the
tag, and its story in the history file or a memory. The format gate refuses anything else, and the size ratchet
refuses growth past the mark. A judgement rule that keeps being broken should earn a gate and be re-tagged.

## Not done, and next
- `grocery.md` (19,460 B), ThriftyCrew `CLAUDE.md` (18,125 B) and the other rules files are not converted. Each is
  converted the same way (history file, tags, add to the manifest) and joins the gate when it is.
- The saving is an ESTIMATE until measured: the next triage run's `triage-cost.py --first-call` shows the new jump
  per load (was 61k to 70k tokens). Bar written now: under 45k tokens per load.
- Whether each kept sentence says what its full account says is a human read, not a gate
  (`audit-rule-format.ps1`'s scope line says so).

## Knowledge consulted
- `design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md` W2.3 and D2 (option A kept, option B's three
  missed bars), and W6.6 (the always-loaded ratchet reused here, not rebuilt).
- memory:always-on-delivery-is-not-sufficient (a rule loaded every turn was still broken; the gate stops a repeat).
- `.claude/rules/ops-and-gates.md` itself: a ratchet's plain run never writes its mark (`-Tighten` does); a new
  detector owes a SCOPE OF A CLEAN REPORT line, a COMPLETE marker and at-bar/past-bar cases.
