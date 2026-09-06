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
| B1 | **E1 rest** | R2 seam (nothing to hook - measured); `publish.ps1` staging-aware; write-seam ratchet | `DONE b30d4e54` |
| B2 | **E6** | Fact Check List before publish | `DONE a90b2081` |
| B3 | **E3b** | Explicit `tools:` on all four + `ops/audit-agent-tools.ps1` gate | `DONE 9c42bd8e` |
| B4 | **E14** | 5 scoped `.claude/rules/` files; field is `globs` not `paths` | `DONE a8b17d05` |
| B5 | **E13** | Resolver block on all 12 agents + citation gate; 2 dangling found | `DONE 6f3b6fd5` |
| B6 | **E12** | `ops/audit-ruling-drift.ps1` - document-to-code drift; 3 violations baselined | `DONE 28151c39` |
| B7 | **E9** | Split already existed; gate fails a missing model/effort pin, prints the matrix | `DONE 993ec7c6` |
| B8 | **E10** | `--status-every` heartbeat that names a STALL | `DONE 9301d154` |
| B9 | **E11+E18** | `validate_tool_path` + first-ever gate on `graph/agentic` | `DONE d2dc0cd5` |
| B10 | **E5** | 2 of 3 already correct; capture drop count read by nobody + gate | `DONE ec7071c6` |
| B11 | **E4** | Premise holds. Probe: BM25 recall@10 = 16/31. Head-to-head vs cosine NOT run. | `DONE d77ab681` |

## C. Loose ends found during the run

Written down as instructed, worked after section B.

| # | What | Why it matters | State |
|---|---|---|---|
| C1 | `ops/prompt-backup/` was stale for 15 files | it is the backup, and it did not have the current prompts | `DONE 182a4152` |
| C2 | Fresh-checkout CRLF: 2 gates red in ANY worktree over bytes | diagnosed, precedent named; fixing it is a semantic ruling | `OPENED as E19` |
| C3 | Scope drift WAS already detected - but `audit-prompt-backup.ps1` was not in run-gates | a check that works and is not run is not protection | `DONE` - registered |
| C4 | I2b: the 7 MB stray is a full-catalogue scaler sweep (583 slugs x 16 steps); writer is an ad-hoc command, not a script | gate catches recurrence | `CHARACTERISED` |
| C5 | Mojibake writer FOUND: `send-alert.ps1` had 3 bare `Get-Content` reads; queue read-modify-write corrupted a generation per alert | fixed as a class across 4 files | `DONE` |
| C6 | E15 behavioural check owed on next real invocation of each of the three skills | structural check shipped; behaviour unobserved | `CARRIED` - cannot be run safely here |
| C7 | `projects/C--Codex/memory` is its own repo, 16 commits, **no remote** | same disk exposure as I1 | BLOCKED-ON-BRAD |

## D. Brad's bucket

| ID | What | State |
|---|---|---|
| I1 remote | private repo URL, or approve installing `gh` | BLOCKED-ON-BRAD |
| I3 | backed up to `~/.claude/workspace-context/` | `DONE ff40c8d` (~/.claude repo) |
| I4 | Fantasy under git: 313 files, 5.4 MB of 1.2 GB | `DONE 19473ed` (Fantasy repo) |
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


---

## E. What is left, and who it belongs to

Written 2026-09-06 at the end of the run. Sections A, B and C are closed; D is not, and none of what
remains is blocked on more work by me.

### Needs Brad, and cannot be done without him

| | What is needed | Why it cannot be done here |
|---|---|---|
| **I1 remote** | an empty PRIVATE repo URL, or approval to install `gh` | `gh` is not installed on this machine. The local repo is committed and clean (175 files); it protects against a bad edit and NOT against the disk, which is what I1 is about. |
| **C7** | a second private repo, or a ruling to flatten | `projects/C--Codex/memory` is already its own repo, 16 commits, no remote. Nesting it would make it a broken gitlink and lose that history. |
| **I4 remote** | a third private repo URL | Fantasy now has history and no remote, same exposure as I1. |
| **I5** | click enroll on `building-with-the-claude-api` | Coursera will not reinstate it by any route I have. |
| **I6 / E8** | a ruling on permission modes | Permission settings are not mine to alter, per the backlog's own ruling. "Complete everything" does not override a rule about who may change a security setting. |

### Ruled, not built - each needs a decision rather than an implementation

| | The decision |
|---|---|
| **E19** | Should `golden-test` compare NORMALISED content rather than bytes? Byte-exactness is arguably the point of a frozen fixture. Diagnosis, measurement and the in-repo precedent are in the backlog entry. |
| **E1 arming** | Both mechanisms are off. Turning either on is a live-site change. |
| **E1 R2** | Not covered, and there is nothing to hook - no R2 write path exists in this repo. |
| **E4 build** | BM25 recall@10 was 16/31. The decisive head-to-head against cosine needs the sidecar venv. |
| **E9 downgrade** | `recipe-hunter-extractor` is the MATE candidate. Needs a fidelity run, not a guess. |
| **E17** | Deliberately won't-fix, unchanged. |

### Carried, not closable in this session

**C6.** The three ask-for-input skills were verified structurally - the statement is last, it names the
question tool, it carries its regime. The behavioural check is owed on the next real invocation of
each. For `recipe-hunter` it cannot be bought here at any price: a failed guard publishes to a live
paid site, and that is not a measurement worth taking that way.
