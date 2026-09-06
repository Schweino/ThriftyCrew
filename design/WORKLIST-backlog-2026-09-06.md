# Worklist: finish the course backlog

Live tracker for the run that closes `BACKLOG-course-findings.md`. Ordered as ruled 2026-09-06.
**Update the state column as work lands.** This file exists so a compacted or resumed session can pick
up without re-deriving anything, and so "done" always names a commit.

State: `TODO` · `WIP` · `DONE <sha>` · `BLOCKED-ON-BRAD` · `WONTFIX`

---

## A. Shipped before this run

| ID | State |
|---|---|
| E2 bare exit codes | `DONE 5a7fccf0` |
| I2a stray-root gate | `DONE 558321d5` |
| E15 ask-for-input | `DONE 8e3de6d9` |
| E7 worktree seeding | `DONE 4e8102c2` |
| E3a situational tools (8 agents) | `DONE 803af3d2` |
| E16 bash hooks | `WONTFIX` - measured, no change owed here |
| E17 skill invocation flags | `WONTFIX` - ruled before this run |
| E1 safety layer, both mechanisms | `DONE 723be4ad` (partial - see B1) |
| I1 skills under version control | local repo `a3e5f47`; remote `BLOCKED-ON-BRAD` |

## B. The plan's order, remaining

| # | ID | What | State |
|---|---|---|---|
| B1 | **E1 rest** | R2 seam; teach `publish.ps1:285` about staging. Arming is Brad's call. | TODO |
| B2 | **E6** | Fact Check List before publish | TODO |
| B3 | **E3b** | Explicit `tools:` on the four agents that declare none. **Ruled: explicit lists on all four.** | TODO |
| B4 | **E14** | Split root CLAUDE.md into path-scoped `.claude/rules/` | TODO |
| B5 | **E13** | Briefs name memory PATHS, not restated content | TODO |
| B6 | **E12** | Document-as-implementation, scoped past `audit-twin-drift` | TODO |
| B7 | **E9** | Model per call, not per agent. Verify `claude-opus-4-8` is real first. | TODO |
| B8 | **E10** | End-of-iteration progress tracking in the hunt daemon; calibrate N | TODO |
| B9 | **E11+E18** | Tool decorators **with** argument validation. Together or not at all. | TODO |
| B10 | **E5** | Validate at source; low confidence to review, not rejection | TODO |
| B11 | **E4** | BM25 + RRF alongside embeddings. **Gated on confirming the premise still holds.** | TODO |

## C. Loose ends found during the run

Written down as instructed, worked after section B.

| # | What | Why it matters | State |
|---|---|---|---|
| C1 | `ops/prompt-backup/` is stale: 4 of 5 E2 files unmirrored, **0 of 8** E3a blocks mirrored | it is the backup, and it does not have the current prompts | TODO |
| C2 | Fresh-checkout CRLF: `golden-test` + `ghost-drift` red in ANY worktree over bytes | every worktree gate starts 2 red; trains people to ignore red | TODO - open as **E19** |
| C3 | `~/.claude/agents/` duplicates `.claude/agents/`; drifted during E2, re-synced by hand | no gate watches it; silent divergence | TODO - open as **E20** |
| C4 | I2b: 3 of 4 stray-root writers unfound (7 MB scaler TSV, collapsed capture-sink path, probe-candidates) | the gate catches recurrence, not the cause | TODO |
| C5 | Mojibake writer in `grocery/triage-queue.json` unfound | if `audit-json-encoding` reddens again it is live | TODO |
| C6 | E15 behavioural check owed on next real invocation of each of the three skills | structural check shipped; behaviour unobserved | TODO - carry |
| C7 | `projects/C--Codex/memory` is its own repo, 16 commits, **no remote** | same disk exposure as I1 | BLOCKED-ON-BRAD |

## D. Brad's bucket

| ID | What | State |
|---|---|---|
| I1 remote | private repo URL, or approve installing `gh` | BLOCKED-ON-BRAD |
| I3 | back up `C:\Codex\CLAUDE.md` and `Fantasy\CLAUDE.md` | TODO - doable by me |
| I4 | `git init` Fantasy (212 py files, no VCS) | TODO - doable by me |
| I5 | Coursera re-enroll on `building-with-the-claude-api` | BLOCKED-ON-BRAD - needs his click |
| I6 / E8 | permission modes: bypass-with-no-sandbox, and "don't ask" for unattended runs | BLOCKED-ON-BRAD - **I will not alter permission settings**; the backlog's own ruling |

---

## Standing rules for this run

- Gate from the MAIN checkout: `ops/run-gates.ps1`, exit 0 only. 1 = fail, 3 = could-not-evaluate and
  never a pass. Read the verdict LINE.
- One commit per item, message says what was broken and why the fix is shaped that way, shipped with
  `-F`. Stage explicit paths, never `git add -A`.
- A sibling session works the same checkout and pushes to main. Fetch before merging; if a rebase
  renumbers commits, re-point any sha this file or a ledger cites.
- Every rule written into any file names the regime it holds in.
