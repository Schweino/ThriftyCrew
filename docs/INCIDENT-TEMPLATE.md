# Incident record template

Copy this to `<area>/INCIDENT-<yyyy-mm-dd>-<slug>.md` when something breaks badly enough to be worth
a record. **There is exactly one prior example and it is a good one**:
`grocery/INCIDENT-2026-07-23-walmart-flood.md`. Read it before writing a new one - this file is the
skeleton, that file is the standard.

**Why this exists (2026-09-08, backlog I34).** The estate wrote one excellent postmortem and never
wrote a second, and the half of it that survived into standing policy was the **preventive** half -
`CLAUDE.md`'s *"when a defect recurs, the durable fix is a memory, a gate or a command, not just the
repair."* The other two kinds of corrective action did not survive, and there is a structural reason
to expect that rather than treat it as an oversight: **a must-fire fixture is a preventive artefact
by construction.** A test philosophy built entirely out of them keeps prompting for prevention and
never prompts for *"would we notice this faster next time"*. So the three-way split below is the
whole point of the template. If you write only the first column, the template has failed.

**This is a template, not a process.** Nobody is asking for a scheduled postmortem practice. The
repo's first commit is 2026-07-08 and there has been one incident record in its whole life; on a base
rate that thin a standing process is ceremony. The template costs nothing to keep and means the next
incident, whenever it lands, is not written from scratch.

---

## Header

```
# INCIDENT <yyyy-mm-dd> - <what broke, in Brad's words>

Severity:   <what it cost. Money, reader-facing wrongness, or time>
Detected:   <when, and BY WHAT - a gate, an alert, or a human noticing>
Resolved:   <when>
Author:     <who wrote this>
```

## Timeline

Timestamped, one line per event, including the events where nothing happened and should have.
**The gap between "it broke" and "we noticed" is the most valuable line in the whole document** and
it only exists if the timeline is honest about both.

## Root cause (the five whys)

Keep asking until the answer stops being about a person and starts being about the system.

## The class (this has happened before)

Refuse to stop at the single cause. Name the other places in the estate that have the same shape,
whether or not they have fired yet. The prior incident's re-review found a blind spot the preventive
fixes had *just created*, and it found it by asking this question.

## Corrective actions - ALL THREE KINDS

This is the section the template exists for. Fill in every row, and if a row is genuinely empty,
write *"none needed, because ..."* rather than deleting it - an absent row and a considered
"nothing" are indistinguishable afterwards.

| Kind | The question it answers | Typical artefact here |
|---|---|---|
| **Preventive** | what stops the cause recurring? | a gate, a must-fire fixture, a `CLAUDE.md` rule, a memory |
| **Detective** | what would find it FASTER next time? | a new check, a floor on a rate, a row in `expected-automations.json`, a `<NAME>-COMPLETE` marker |
| **Responsive** | what makes the response to this SHAPE better? | a runbook line, a rollback path, an undo, a `-DryRun` |

Each action gets a **`Verified:`** line saying what was actually observed - not what was intended.
A fix with no `Verified:` line is a plan, not a fix.

## What worked

Not decoration. The thing that limited the blast radius is a thing to protect from a future
refactor, and nobody will know it mattered unless it is written here.

## Accepted risks

What is deliberately NOT being fixed, and the bound on what that costs. Stating a bound is what
separates an accepted risk from an unexamined one.

## Independent re-review

Someone who did not write the record reads it and answers two questions: is the root cause right,
and did the fixes create a new blind spot. On the one incident this estate has, that pass corrected
the RCA's own attribution and found two further gaps. It is the highest-yield section here.
