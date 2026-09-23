# Phase 0 - before 2026-09-25

Part of `design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md`. Read that file's sections 4, 6 and 8, and your item's row in section 5, first. Paste
its Knowledge consulted excerpts into any brief you write. An evidence id such as "record-tier/x" resolves to
`design/brain-review-2026-09-22/digest-record-tier.md`, finding x.

## W0.1 The Store: resolver accepts estate knowledge

**Repo:** ThriftyCrew. **Lands via:** `ops\push-main.ps1` from a clean seeded worktree. **Effort:** S-M.
**Brad:** D1. If this cannot land by the end of 2026-09-24, moving REFUSE_FROM is his call, not the implementer's.

**Why.** From 2026-09-25, `ops/store_citation.py` refuses any commit whose Store: line cites the estate's own rules,
design docs or code:
- `resolve()` looks only in `~/.claude/skills`, `~/.claude` and the two memory dirs;
- PATH_RE does not match `lib/x.ps1` at all, and it cuts `.claude\rules\r.md` down to `r.md`.

Replaying 2026-09-20..22 refuses 574722dab, 748967ad4, affeb7254 and e5d0a00a1, every one for an estate citation. This
refuses exactly what goal 1 asks for. (record-tier/resolver-refuses-estate-knowledge; plan-review-evidence)

**Files.**
- `ops/store_citation.py`.
- A new committed replay harness, `ops/replay-store-citations.py`. It is committed FIRST, in its own commit, so the bar
  names a harness blob.

**Steps.**
1. **The replay harness first.** `ops/replay-store-citations.py --since <ISO> --until <ISO> [--today YYYY-MM-DD]
   [--all-store-lines]`. For each non-merge commit on origin/main in the window with a Claude co-author trailer, it:
   - takes that commit's changed code files (`store_citation.is_code` over `git show --name-only --diff-filter=ACMR`);
   - takes its own tracked set (`git ls-tree -r --name-only <commit>`);
   - runs `judge_message` with `today`;
   - prints one row per commit (sha, verdict, why, cited, cited_kinds), then `judged=N refused=R blind=B`, then a
     `REPLAY-STORE-CITATIONS-COMPLETE` last line.
   `--all-store-lines` also prints how many commits carrying any Store: line change verdict against HEAD's resolver, in
   either direction. Self-test: a temp repo with two commits, one citing a tracked rules file and one citing nothing,
   gives the expected two verdicts. The `--today` override lives ONLY in this harness and in store_citation's
   `--selftest` path, never in the commit-msg path.
2. **Normalise the joined Store: body BEFORE `PATH_RE.findall`, never the tokens after it.**
   - convert backslashes to `/`;
   - then remove every occurrence of `~/.claude/skills/`, `C:/Users/Owner/.claude/skills/` (case-insensitive),
     `<repo_root>/` and a bare `skills/` wherever one STARTS a token: at the start of the body, or after whitespace, `(`,
     `;`, `,` or a quote. Not only at the start of the body, since judge_message joins every Store: line into one body
     (store_citation.py:158-159).
3. **Add exactly this alternative to PATH_RE:** `[\w.-]+(?:/[\w.-]+)+\.(?:md|ps1|psm1|py|js|json)`. It requires at
   least one `/`, so a bare code basename inside prose (`hold-recipe.ps1`) is never extracted. It can then neither pass
   nor refuse a line: 93ef5df50 and ce642822d carry such prose today.
4. **Pass `repo_root` and `tracked`** through the `store` dict:
   - `repo_root` comes from `git rev-parse --show-toplevel`;
   - `tracked` comes from ONE `git ls-files` call;
   - both run with the INHERITED env. Under a pathspec commit, `GIT_INDEX_FILE` names the index being committed. Never
     call `Clear-TcGitRepoEnv`, or scrub `GIT_INDEX_FILE`, in this path.
5. **`resolve()`** tries the store bases first. It then accepts a repo-relative token only when the token is in
   `tracked`. A bare `<name>.md` falls back to `.claude/rules/<name>` ONLY after every store base misses.
   - Leave the bare `CLAUDE.md` case alone: it already resolves through the `~/.claude` store base today, and closing
     that is W6.11's job, under its own warn date.
6. **A staged code file cannot cite itself.** Drop tokens equal to any staged code path before judging.
7. **Record new fields on the decision-log row, and never refuse on any of them:**
   - `cited_kinds`: any of store, memory, rules, design, machinery;
   - `repo_blind`;
   - `rules_without_section`: the token is a rules file and the line names no bullet.
8. **If `git ls-files` fails,** accept repo tokens with `repo_blind: true`. A could-not-look never refuses (header line
   35).
9. **Refusal text.** Change the example at about line 236 to `Store: .claude/rules/ops-and-gates.md ("A catch around a
   native redirect is not a guard"); lib/atomic-write.ps1 (reused)`. Change the command to the section 4.7 string
   without `--estate`. The agent prompts and the triage task carry the same example and command; W5.2 updates them (not
   this item, so this item stays one file).
10. **Bump `expected = 24`** (line 335) to the new case count.

**Fixtures** (in `selftest()`, temp git repo; the eight git variables cleared from the FIXTURE's child env only).
Setup: a tracked `.claude/rules/r.md` and a tracked `lib/x.ps1`.
- MUST NOT FIRE: `.claude/rules/r.md` passes.
- MUST NOT FIRE: `lib\x.ps1` (backslash) resolves, with `cited == ['lib/x.ps1']` and kind machinery. The
  `.claude\rules\r.md` form proves nothing, because it passes through the bare fallback even with no normalisation.
- MUST NOT FIRE: a bare `r.md` resolves through .claude/rules.
- MUST NOT FIRE: for the Store: lines of 93ef5df50 and ce642822d, copied verbatim, `cited` contains no token ending
  `.ps1`: `audit-alert-precision.ps1` and `hold-recipe.ps1` stay unextracted.
- Every MUST FIRE case in this list calls judge_message with `today='2026-09-25'`.
- MUST FIRE: `.claude/rules/nope.md` is refused on the refuse date.
- MUST FIRE: an UNTRACKED file present on disk is refused. This proves the tracked test, not `os.path.exists`.
- MUST FIRE: a line citing only the staged code file itself is refused.
- CLEAN TWIN: `memory:ps-null-count-is-one` still resolves.
- CLEAN TWIN: an unlistable repo gives `repo_blind` and ok.

**Bar (written now).**
- `ops/replay-store-citations.py --since 2026-09-20T00:00:00 --until 2026-09-22T19:08:00 --today 2026-09-25`, with
  explicit bounds on both ends (a date-only `--since` starts at the current time of day):
  - the 4 named commits pass;
  - 0 of the window's judged commits are refused;
  - `repo_blind` is false on every row.
- Print the judged count. The record-tier review counted 56 and a later re-run counted 61; either is fine, printed.
- `--all-store-lines --since 2026-09-15T00:00:00`: print the verdict changes in either direction. Every change must be a
  refusal that became a pass.

**Traps.**
- Scrubbing `GIT_INDEX_FILE` makes the check read the SHARED index, so it judges other sessions' staged files.
- Normalising after `findall`.
- A bar replay without per-commit tracked sets passes vacuously through `repo_blind`.
- A shipped fix binds only checkouts rebased past it (W0.2).

**Done when.**
- `C:/Codex/Python312/python.exe ops/store_citation.py --selftest` exits 0, with its verdict as the last line.
- The harness self-test exits 0.
- The bar holds.
- It landed on origin/main before the end of 2026-09-24, and the commit message cites the harness blob and the replay
  counts.

## W0.2 A checkout with no copy of the rule says BLIND

**Repo:** ThriftyCrew. **Lands via:** `ops\push-main.ps1`. **Effort:** S.

**Why.** `ops/hooks/commit-msg` runs `$top/ops/store_citation.py` from the committing checkout, and exits 0 silently
when the file is absent. On 2026-09-22:
- 57 of 92 checkouts had no copy, 29 ran the 09-18 resolver, and 6 ran the current one;
- only 8 of 92 had a HEAD commit in the last 3 days: 6 current and 2 stale. (critic, Newly measured 3)

Keep the per-checkout copy design, so a branch can test its own edit to the rule, and make the absence loud.

**Steps.**
1. In `ops/hooks/commit-msg`, when `CLAUDE_CODE_SESSION_ID` is set and the script is missing, print this to stderr and
   exit 0: `store-citation: BLIND - this checkout has no ops/store_citation.py; the commit is not judged`.
2. AFTER push-main lands the change, run `powershell -NoProfile -File ops\install-hooks.ps1` from a checkout whose HEAD
   is that landed commit. It writes every file of that checkout's `ops\hooks` into the shared
   `C:\Codex\ThriftyCrew\.git\hooks`, so never run it from the feature worktree first.
3. Then run `ops/audit-hook-installed.ps1` and read exit 0.
4. Name the 2 active stale checkouts in the commit message, so their owners rebase.

**Fixtures** (a new case in store_citation's self-test, which runs the hook script in a temp repo; bump `expected`):
- MUST FIRE: with no `ops/store_citation.py`, the BLIND line is on stderr and the exit is 0.
- CLEAN TWIN, date-independent (the self-test runs on every push, including after 2026-09-25): with the script
  present, CLAUDE_CODE_SESSION_ID set, and USERPROFILE pointed at a temp home holding an empty `.claude/skills` dir, a
  code commit whose Store: line cites the temp repo's tracked `.claude/rules/r.md` reaches store_citation. The commit
  lands (exit 0), and exactly one row with verdict ok is appended to the temp home's `store-citation-log.jsonl`. The
  temp home keeps both the BLIND-no-store branch and the live decision log out of the case. The warn/refuse split stays
  in judge_message's own dated fixtures.
- Add no date override that the commit-msg path can read.

**Done when.** The fixtures pass, the hook is installed from the landed commit, and `audit-hook-installed.ps1` exits 0.
