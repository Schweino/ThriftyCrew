r"""store_citation.py - did the change say what the knowledge store told it?

    python ops/store_citation.py                      # plan audit (run-gates runs this, no arguments)
    python ops/store_citation.py --commit-msg <file>  # the commit-msg hook calls this
    python ops/store_citation.py --selftest           # frozen fixtures, hermetic

WHY THIS EXISTS (Brad, 2026-09-18). The knowledge store (~/.claude/skills and the memory directory) holds
the engineering rules this estate has paid for, and nothing made a session USE them. Measured that day:
the backlog run made real code fixes across dozens of subagents with 0 store searches and 127 of 127
replies reading "Consulted: nothing relevant". The one fix that searched first (2c6a2b5b5, the graph
import) came out with a better design BECAUSE of it. Pushing knowledge at a session automatically was
measured and refused twice (the file-path signal and edit-time craft recall, both 2026-09-12), and a
prose rule delivered every turn was broken six times (memory always-on-delivery-is-not-sufficient).
So this does not try to recall anything. It checks the RECORD, at the two places a decision is written
down, and a record either exists and resolves or it does not - that part has an exit code.

TWO CHECKS.
  1. A dated design/<PREFIX>-*.md, for every PREFIX in ANALYSIS_RECORD_PREFIXES (PLAN and MEASURE until
     2026-09-23; RCA, REVIEW, EVAL and the rest since W5.3), dated on or after PLAN_CUTOFF carries a
     `## Knowledge consulted` section with something under it. Older records are not judged, so this is
     at zero on the day it lands and needs no ratchet. The section is checked for PRESENCE only: the
     tokens inside it are never resolved here, because a record's prose names files the way a reader
     would, and a push gate that warned on every one would warn every pusher about docs they never wrote.
  2. A commit made by a Claude session (CLAUDE_CODE_SESSION_ID is set) that changes CODE carries a
     `Store:` line naming the store files it used, or `Store: searched <terms>, nothing applicable`.
     Every named file must RESOLVE. A human commit and the daily bot have no session id and are not
     judged; neither is a merge, nor a commit that touches no code. `Store-Exempt: <reason>` is the
     loud, logged way out for a mechanical commit (a rename, a revert, a data refresh).

WARN, THEN REFUSE (Brad's ruling, 2026-09-18). Until REFUSE_FROM the commit check prints its finding and
lets the commit through; from that date a missing or unresolvable line refuses the commit. The week in
between is measured by ~/.claude/skills/store-usage-report.py off the decision log this appends to, and
the date is the one line to move if that week shows the rule crying wolf.

WHAT "BACKED" MEANS. knowledge-search's search.py logs every search with the session id (02da8e6, store
repo). A `Store:` line from a session with NO logged search in the last BACKING_HOURS is recorded as
unbacked. That is logged and reported, never refused: a session id can go missing for reasons that are
not the author's, and a could-not-look must not settle the question.

A CITATION MAY NAME THE ESTATE'S OWN KNOWLEDGE (2026-09-23, W0.1 of
design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md). Until that day a token resolved only against
~/.claude/skills, ~/.claude and the memory stores, so `.claude/rules/ops-and-gates.md`, a design/ doc or a
reused `lib/atomic-write.ps1` read as unresolved - and from REFUSE_FROM that would REFUSE exactly the commits
that used the estate's own rules and machinery. A replay of 2026-09-20..22 (ops/replay-store-citations.py)
refused 4 of 61 for that reason and no other. So now:
  - the Store: body is normalised BEFORE extraction (backslashes, then any home-skills, `skills/` or
    repo-root prefix at the start of a token), because extracting first cut `.claude\rules\r.md` to `r.md`;
  - a repo path with a code or config extension is a citation only when it holds a `/` (a bare
    `hold-recipe.ps1` in prose is not extracted, so it can neither pass nor refuse a line);
  - a token resolves when the committing checkout TRACKS it (`git ls-files`, run with the INHERITED env: under
    a pathspec commit GIT_INDEX_FILE names the index being committed), and a bare `<name>.md` falls back to
    `.claude/rules/<name>.md` only after every store base misses;
  - a staged code file cannot cite itself, and when the repo cannot be listed the token is accepted and the
    row says `repo_blind` - a could-not-look never refuses.
The decision row records `cited_kinds`, `repo_blind`, `self_cited` and `rules_without_section` (a rules file
cited with no bullet named). None of them refuses; the weekly report reads them.

THE BRAIN REPO IS JUDGED BY THE SAME RULE (2026-09-23, W4.5 step 0). When the committing checkout is not a
ThriftyCrew checkout - the ~/.claude repo, whose own commit-msg hook calls THIS file in the main checkout - a
repo-relative token also resolves against the estate's tracked set (RECALL_ESTATE_ROOT, default
C:\Codex\ThriftyCrew), because a brain change legitimately cites `.claude/rules/*.md` or a design doc that only the
estate holds. The row records `resolved_in` per token (store, memory, repo, estate or repo_blind). A brain commit
refuses only from BRAIN_REFUSE_FROM, which is None - warn only - until Brad sets it (D17). A commit from a LINKED
worktree of the brain repo (the C:/Users/Owner/.claude-wt/* lanes) is a brain commit too: is_brain_checkout reads
every repo root, not only the toplevel, because a worktree's toplevel is never the brain home.

THE CHEAP ESCAPES ARE MEASURED BEFORE THEY ARE CLOSED (2026-09-23, W6.11). Three forms pass the letter of the rule
and say nothing a reader can check: `searched ..., nothing applicable` with no quoted term, a citation set made only
of index files (CLAUDE.md, MEMORY.md, memory:MEMORY, CATALOGUE.md, knowledge-search/SKILL.md, knowledge/SKILL.md),
and a `Store-Exempt:` reason under three words. Each is recorded as verdict `escape-warn` with `escape` naming the
form, and the hook prints a NOTE and lets the commit through, until ESCAPES_REFUSE_FROM is set (D1b).

SCOPE OF A CLEAN REPORT: sound for what it checks and nothing more. A clean plan audit proves every new
plan HAS the section, never that the section is honest or that the design used it well; a judgement has
no exit code. A clean commit check proves the named files exist, not that they were read.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time

PLAN_CUTOFF = "2026-09-20"   # plans named with an earlier date are not judged (first day after landing)
REFUSE_FROM = "2026-09-25"   # Brad, 2026-09-18: one week of warnings, then refuse. First value, not a sweep.
# A COMMIT TO THE BRAIN REPO (~/.claude) is judged by this same rule once its own hook calls it (W4.5 of
# design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md), and it WARNS until Brad sets this date.
BRAIN_REFUSE_FROM = None     # Brad sets this (D17); None means warn only
# THE CHEAP ESCAPES (W6.11): an unquoted "searched ..., nothing applicable", a citation set made only of index
# files, and a Store-Exempt reason of fewer than three words. Measured first, recorded as escape-warn, never refused
# until this is set. It never goes through the REFUSE_FROM mode, which is already refuse by the time this lands.
ESCAPES_REFUSE_FROM = None   # Brad sets this (D1b); None means warn only
BACKING_HOURS = 24           # a search this recent in the same session backs a Store: line. First value.
# THE MEMORY STORES A CITATION MAY NAME, in lookup order (2026-09-22, queue 2026-09-22-7d991c). Claude Code keys
# a session's memory directory on the directory it was LAUNCHED from, so this estate has two live stores:
# sessions opened in C:\Codex\ThriftyCrew write C--Codex-ThriftyCrew\memory (187 memos that day) and sessions
# opened in C:\Codex write C--Codex\memory (199, e.g. ps51-bomless-read-is-cp1252, which is in no other).
# Until this list existed the resolver read only the first, so every commit citing a real memo from the second
# would have been REFUSED from REFUSE_FROM. This tuple is the one place that fact lives; a third launch root
# with its own store is added here, never by a second copy of the path somewhere else.
MEMORY_PROJECTS = ("C--Codex-ThriftyCrew", "C--Codex")

CODE_EXT = {".ps1", ".psm1", ".py", ".js", ".ts", ".sql", ".sh"}
NOT_CODE_PREFIX = ("grocery/out/", "archive/", "meal-prep/out/", "ops/prompt-backup/")
# THE ANALYSIS RECORDS THE PLAN AUDIT JUDGES (2026-09-23, W5.3 of
# design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md). Until that day only PLAN- and MEASURE- were
# judged, so an RCA, a REVIEW or an EVAL - the records a diagnosis or a verdict is written into - could say
# nothing about what it consulted and pass. This tuple is the ONE definition: ~/.claude/skills recall_core
# mirrors it as ANALYSIS_RECORD_PREFIXES with a comment naming this file, and a prefix is added here first.
# FINDING and FINDINGS are both real (design/FINDING-*.md and design/FINDINGS-contested-2026-08-21.md).
ANALYSIS_RECORD_PREFIXES = ("PLAN", "MEASURE", "EVAL", "TRIAL", "RCA", "REVIEW", "AUDIT", "FINDING", "FINDINGS", "PROBE")
PLAN_RE = re.compile(r"^(" + "|".join(ANALYSIS_RECORD_PREFIXES) + r")-.*?(\d{4}-\d{2}-\d{2}).*\.md$")
HEADING_RE = re.compile(r"^##\s+knowledge consulted\s*$", re.I | re.M)
STORE_LINE_RE = re.compile(r"^store:\s*(.*)$", re.I | re.M)
EXEMPT_RE = re.compile(r"^store-exempt:\s*(\S.*)$", re.I | re.M)
NOTHING_RE = re.compile(r"\bsearched\b.*\b(nothing|none)\b.*\bapplicable\b", re.I)
# W6.11: a nothing-applicable claim names WHAT was searched, as at least one quoted term after `searched`
# ('searched "regex timeout", nothing applicable'). NOTHING_RE itself is unchanged, so "nothing further
# applicable" still reads as the claim; this only says whether the claim carries its terms.
NOTHING_QUOTED_RE = re.compile("\\bsearched\\b.*?(?:\"[^\"]+\"|'[^']+'|\u201c[^\u201d]+\u201d|\u2018[^\u2019]+\u2019)", re.I)
# W6.11: the INDEX files, keyed on basename after resolution. They say where knowledge lives, so a citation set
# made only of them names no knowledge. A SKILL.md is an index only in these two skills; any other is a subject.
INDEX_BASENAMES = ("claude.md", "memory.md", "catalogue.md")
INDEX_SKILL_DIRS = ("knowledge-search", "knowledge")
EXEMPT_MIN_WORDS = 3         # W6.11: "Store-Exempt: rename" says nothing a reader can check. First value.
# W4.5 step 0: a commit to a repo that is NOT a ThriftyCrew checkout (the brain repo) may cite the estate's own
# rules, designs and libraries, so its tokens also resolve against the estate's tracked set. RECALL_ESTATE_ROOT is
# the one name for that root across the brain's hooks (recall-brain, recall-effort and recall-inbox read it too).
ESTATE_ROOT_DEFAULT = r"C:\Codex\ThriftyCrew"
GIT_REPO_VARS = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
                 "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX", "GIT_NAMESPACE")
# A repo path with a code or config extension counts only when it holds a '/': a bare basename in prose
# ("superseded by hold-recipe.ps1", ce642822d) is description, not a citation. Markdown keeps its bare form,
# because a bare `grocery.md` is how the rules files are cited (e5d0a00a1).
REPO_PATH_ALT = r"[\w.-]+(?:/[\w.-]+)+\.(?:md|ps1|psm1|py|js|json)"
PATH_RE = re.compile(r"(?:memory:[\w.-]+|\[\[[\w.-]+\]\]|" + REPO_PATH_ALT + r"|[\w.-]+(?:/[\w.-]+)*\.md)")
# Where a token STARTS: the start of the body, or after whitespace, a bracket, a separator or a quote.
TOKEN_START = r"(?:^|(?<=[\s(\[;,\"'“‘]))"
# A SECTION TITLE IS NOT A CITATION (2026-09-23). `course/CONSOLIDATE.md ("Everything about `applies-here.md`")` names
# ONE file and the section inside it, but PATH_RE also read the bare `applies-here.md` in the title, which resolves
# nowhere, so from REFUSE_FROM the line would have refused. Before extraction every quoted span is blanked (a title or a
# search term, never a citation: 0 of 272 Store: lines from 2026-09-15 to 2026-09-23 held a path inside quotes), and so
# is a parenthesised span that FOLLOWS a citation, the section designator rules_without_section already reads. A
# parenthesis anywhere else keeps what it holds, so `reused (lib/x.ps1)` still cites. A straight single quote opens a
# span only at a token start and closes only before a non-word character, so an apostrophe (estate's) is never a quote.
QUOTE_CLOSE = {'"': '"', "“": "”", "'": "'", "‘": "’"}
ENDS_IN_CITATION_RE = re.compile(r"(?:" + PATH_RE.pattern + r")\s*$")
HOME_SKILLS_PREFIXES = (r"~/\.claude/skills/", r"[a-z]:/users/[^/\s]+/\.claude/skills/", r"skills/")


def home_store():
    h = os.path.join(os.environ.get("USERPROFILE") or os.path.expanduser("~"), ".claude")
    return {"skills": os.path.join(h, "skills"),
            "memory": os.path.join(h, "projects", MEMORY_PROJECTS[0], "memory"),
            "memories": [os.path.join(h, "projects", p, "memory") for p in MEMORY_PROJECTS],
            "log": os.path.join(h, "store-citation-log.jsonl"),
            "recall_log": os.path.join(h, "recall-log.jsonl")}


# ---- plan audit -------------------------------------------------------------------------------------

def plan_findings(design_dir, cutoff=PLAN_CUTOFF):
    """(judged, missing): plan files dated >= cutoff, and those without a non-empty section."""
    judged, missing = [], []
    for name in sorted(os.listdir(design_dir)) if os.path.isdir(design_dir) else []:
        m = PLAN_RE.match(name)
        if not m or m.group(2) < cutoff:
            continue
        judged.append(name)
        with open(os.path.join(design_dir, name), encoding="utf-8", errors="replace") as f:
            text = f.read()
        h = HEADING_RE.search(text)
        body = ""
        if h:
            rest = text[h.end():]
            nxt = re.search(r"^##\s", rest, re.M)
            body = (rest[:nxt.start()] if nxt else rest).strip()
        if not body:
            missing.append(name)
    return judged, missing


def run_plan_audit(repo):
    judged, missing = plan_findings(os.path.join(repo, "design"))
    for name in missing:
        print("  MISSING  design/%s has no '## Knowledge consulted' section with content" % name)
    if missing:
        print("store-citation: %d of %d plan(s) dated %s or later name nothing from the knowledge store."
              " Add the section: the search terms you ran and each store file you used, or"
              " 'searched <terms>: nothing applicable'." % (len(missing), len(judged), PLAN_CUTOFF))
    print("STORE-CITATION-PLANS-COMPLETE judged=%d missing=%d cutoff=%s" % (len(judged), len(missing), PLAN_CUTOFF))
    return 1 if missing else 0


# ---- commit check -----------------------------------------------------------------------------------

def is_code(path):
    p = path.replace("\\", "/")
    if p.startswith(NOT_CODE_PREFIX):
        return False
    return os.path.splitext(p)[1].lower() in CODE_EXT or p.startswith("ops/hooks/")


def memory_dirs(store):
    """Every memory store a citation may resolve in: the list when given, else the one legacy key."""
    return list(store.get("memories") or [store["memory"]])


def normalise_body(body, repo_roots=()):
    """The Store: body with backslashes made '/' and any home-skills, `skills/` or repo-root prefix removed
    wherever it STARTS a token. Runs BEFORE extraction: PATH_RE cannot see across a backslash, so extracting
    first turned `.claude\\rules\\r.md` into `r.md` and `lib\\x.ps1` into nothing at all."""
    b = body.replace("\\", "/")
    roots = sorted({r.replace("\\", "/").rstrip("/") + "/" for r in repo_roots if r}, key=len, reverse=True)
    prefixes = [re.escape(r) for r in roots] + list(HOME_SKILLS_PREFIXES)   # longest repo root first
    return re.sub(TOKEN_START + "(?:" + "|".join(prefixes) + ")", "", b, flags=re.I)


def _quote_end(s, i):
    """Index just past the quoted span that opens at s[i], or None when s[i] opens none (see QUOTE_CLOSE)."""
    c = s[i]
    close = QUOTE_CLOSE.get(c)
    if close is None:
        return None
    if c == "'" and i > 0 and not (s[i - 1].isspace() or s[i - 1] in "([;,"):
        return None                                        # an apostrophe, not an opening quote
    j = i + 1
    while j < len(s):
        ch = s[j]
        if ch == "\\" and c == '"' and j + 1 < len(s):
            j += 2                                         # \" inside a double-quoted title does not close it
            continue
        if ch == close or (c == "“" and ch == '"'):
            if c in ("'", "‘") and j + 1 < len(s) and (s[j + 1].isalnum() or s[j + 1] == "_"):
                j += 1                                     # estate's inside a single-quoted title
                continue
            return j + 1
        j += 1
    return None


def _paren_end(s, i):
    """Index just past the parenthesised span opening at s[i], quote-aware; len(s) when it never closes, because a
    Store: line wrapped mid-title (93ef5df50) carries only the title's first half."""
    depth, j = 0, i
    while j < len(s):
        e = _quote_end(s, j)
        if e is not None:
            j = e
            continue
        if s[j] == "(":
            depth += 1
        elif s[j] == ")":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return len(s)


def strip_section_titles(line):
    """One Store: line with every quoted span, and every parenthesised span that follows a citation, blanked to one
    space (see QUOTE_CLOSE). Only what PATH_RE extracts reads this; the search-claim tests and rules_without_section
    read the line as written, so a quoted search term and a named bullet still count."""
    out, i = [], 0
    while i < len(line):
        e = _quote_end(line, i)
        if e is None and line[i] == "(" and ENDS_IN_CITATION_RE.search("".join(out).replace("\\", "/")):
            e = _paren_end(line, i)
        if e is not None:
            out.append(" ")
            i = e
            continue
        out.append(line[i])
        i += 1
    return "".join(out)


def repo_kind(rel):
    r = rel.lower()
    if r.startswith(".claude/rules/"):
        return "rules"
    if r.startswith("design/"):
        return "design"
    if os.path.splitext(r)[1] in CODE_EXT:
        return "machinery"
    return "repo"


def _in_tracked(rel, tracked):
    """The kind of a repo-relative token in one tracked set, with the bare `<name>.md` rules fallback; else None."""
    if rel.lower() in tracked:
        return repo_kind(rel)
    if "/" not in rel and rel.lower().endswith(".md") and (".claude/rules/" + rel.lower()) in tracked:
        return "rules"
    return None


def locate(token, store):
    """(kind, where) for a cited token: kind is memory, store, rules, design, machinery, repo or repo_blind, and
    where is store, memory, repo, estate or repo_blind; (None, None) when it names nothing. Store bases first, then
    the committing checkout's tracked set (store["tracked"], lower-cased repo-relative paths), then - for a commit to
    a repo that is not a ThriftyCrew checkout - the estate's tracked set (store["estate_tracked"], W4.5 step 0), a
    bare `<name>.md` falling back to `.claude/rules/<name>.md` in each. With store["repo_blind"] the committing repo
    could not be listed, so a token nothing else holds is accepted as repo_blind rather than refused."""
    t = token.strip()
    if t.startswith("memory:") or t.startswith("[["):
        name = t[7:] if t.startswith("memory:") else t[2:-2]
        name = name[:-3] if name.endswith(".md") else name
        if any(os.path.isfile(os.path.join(m, name + ".md")) for m in memory_dirs(store)):
            return "memory", "memory"
        return None, None
    rel = t.replace("\\", "/")
    while rel.startswith("./"):
        rel = rel[2:]
    for base in [store["skills"], os.path.dirname(store["skills"])]:
        if os.path.isfile(os.path.join(base, rel)):
            return "store", "store"
    for m in memory_dirs(store):
        if os.path.isfile(os.path.join(m, rel)):
            return "memory", "memory"
    tracked = store.get("tracked")
    if tracked is not None:
        k = _in_tracked(rel, tracked)
        if k:
            return k, "repo"
    estate = store.get("estate_tracked")
    if estate is not None:
        k = _in_tracked(rel, estate)
        if k:
            return k, "estate"
    if tracked is None and store.get("repo_blind"):
        return "repo_blind", "repo_blind"
    return None, None


def resolve_kind(token, store):
    """What a cited token names (see locate), or None when it names nothing."""
    return locate(token, store)[0]


def is_index_citation(token):
    """True when a cited token is an INDEX file (W6.11): CLAUDE.md, MEMORY.md, memory:MEMORY, CATALOGUE.md, or the
    SKILL.md of knowledge-search or knowledge. Keyed on the basename, after normalisation."""
    t = token.strip()
    if t.startswith("memory:") or t.startswith("[["):
        name = t[7:] if t.startswith("memory:") else t[2:-2]
        return name.lower() in ("memory", "memory.md")
    rel = t.replace("\\", "/").lower()
    parts = [p for p in rel.split("/") if p and p != "."]
    if not parts:
        return False
    if parts[-1] in INDEX_BASENAMES:
        return True
    return parts[-1] == "skill.md" and len(parts) >= 2 and parts[-2] in INDEX_SKILL_DIRS


def resolve(token, store):
    """True when a cited token names a real store or estate file."""
    return resolve_kind(token, store) is not None


def rules_without_section(body, token):
    """True when a cited rules file is not followed by a parenthesis or a quote naming which bullet."""
    i = body.find(token)
    if i < 0:
        return False
    rest = body[i + len(token):].lstrip()
    return not rest[:1] in ("(", '"', "'", "“", "‘")


def commit_mode(store, today):
    """warn or refuse for a missing or unresolvable line. The brain repo has its own date (BRAIN_REFUSE_FROM, D17),
    and until Brad sets it a brain commit only warns; every other repo refuses from REFUSE_FROM."""
    if store.get("repo_is_brain"):
        return "refuse" if BRAIN_REFUSE_FROM and today >= BRAIN_REFUSE_FROM else "warn"
    return "refuse" if today >= REFUSE_FROM else "warn"


def escape_verdict(today):
    """What a cheap escape form (W6.11) is recorded as: escape-warn until ESCAPES_REFUSE_FROM is set and reached,
    then refuse. Never d["mode"]: that is already refuse by the time the escapes are measured."""
    return "refuse" if ESCAPES_REFUSE_FROM and today >= ESCAPES_REFUSE_FROM else "escape-warn"


def judge_message(text, code_files, store, today, searched):
    """The decision for one commit message: a dict with verdict ok|exempt|escape-warn|warn|refuse and why."""
    d = {"code_files": len(code_files), "cited": [], "unresolved": [], "backed": searched,
         "mode": commit_mode(store, today),
         "cited_kinds": [], "self_cited": [], "rules_without_section": [], "repo_blind": bool(store.get("repo_blind")),
         "resolved_in": {}, "repo_is_brain": bool(store.get("repo_is_brain")), "escape": None}
    if not code_files:
        d.update(verdict="ok", why="no code changed")
        return d
    ex = EXEMPT_RE.search(text)
    if ex:
        reason = ex.group(1).strip()
        if len(reason.split()) < EXEMPT_MIN_WORDS:
            d.update(verdict=escape_verdict(today), why=reason, escape="short-exempt")
        else:
            d.update(verdict="exempt", why=reason)
        return d
    lines = [m.group(1).strip() for m in STORE_LINE_RE.finditer(text)]
    if not lines or not any(lines):
        d.update(verdict=d["mode"], why="no Store: line")
        return d
    body = normalise_body(" ".join(lines), store.get("repo_roots") or ())
    # Extraction reads the line with its section titles blanked (strip_section_titles); everything else reads body.
    cites_text = normalise_body(" ".join(strip_section_titles(l) for l in lines), store.get("repo_roots") or ())
    staged = {p.replace("\\", "/").lower() for p in code_files}
    found = PATH_RE.findall(cites_text)
    d["self_cited"] = [c for c in found if c.lower() in staged]     # a file cannot back its own change
    d["cited"] = [c for c in found if c.lower() not in staged]
    located = {c: locate(c, store) for c in d["cited"]}
    kinds = {c: located[c][0] for c in d["cited"]}
    d["resolved_in"] = {c: located[c][1] for c in d["cited"] if located[c][1]}
    d["unresolved"] = [c for c in d["cited"] if kinds[c] is None]
    d["cited_kinds"] = sorted({k for k in kinds.values() if k})
    d["rules_without_section"] = [c for c in d["cited"] if kinds[c] == "rules" and rules_without_section(body, c)]
    nothing = bool(NOTHING_RE.search(body))
    # W6.11: a citation set drawn ONLY from index files names nothing, so it stands or falls on the search claim.
    index_only = bool(d["cited"]) and all(is_index_citation(c) for c in d["cited"])
    if d["unresolved"]:
        d.update(verdict=d["mode"], why="cited file(s) do not resolve")
    elif not d["cited"] and not nothing:
        d.update(verdict=d["mode"], why="Store: line names no store file and does not say what was searched")
    elif (not d["cited"] or index_only) and nothing and not NOTHING_QUOTED_RE.search(body):
        d.update(verdict=escape_verdict(today), why="searched, nothing applicable, with no quoted search term",
                 escape="unquoted-search")
    elif index_only and not nothing:
        d.update(verdict=escape_verdict(today), why="cites only index files (%s)" % ", ".join(d["cited"]),
                 escape="index-only")
    else:
        d.update(verdict="ok", why="cited" if d["cited"] and not index_only else "searched, nothing applicable")
    return d


def session_searched(recall_log, sid, now, hours=BACKING_HOURS):
    """True/False when the search log can say; None when it cannot be read."""
    try:
        with open(recall_log, encoding="utf-8", errors="replace") as f:
            for line in f:
                if '"search"' not in line or sid not in line:
                    continue
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if r.get("ev") == "search" and r.get("sid") == sid and now - r.get("t", 0) <= hours * 3600:
                    return True
        return False
    except OSError:
        return None


def repo_context(cwd=None, env=None):
    """{repo_roots, tracked, repo_blind} for the committing checkout.

    git runs with the INHERITED environment unless env is given. Inside commit-msg that is the point: under
    a pathspec commit GIT_INDEX_FILE names the temporary index being committed, and `git ls-files` must read
    THAT index, never the shared .git/index other sessions stage into. Never scrub the git variables here.
    Any failure reads as repo_blind (tracked None), never as an empty tracked set: a could-not-look must not
    refuse a citation."""
    def run(args):
        return subprocess.run(["git"] + args, cwd=cwd, env=env, capture_output=True, encoding="utf-8",
                              errors="replace", timeout=30)
    try:
        top = run(["rev-parse", "--show-toplevel"])
        files = run(["ls-files", "-z"])
        if top.returncode != 0 or files.returncode != 0 or not top.stdout.strip():
            raise OSError("git could not list the repo")
        roots = {top.stdout.strip().replace("\\", "/")}
        common = run(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        c = common.stdout.strip().replace("\\", "/") if common.returncode == 0 else ""
        if c.endswith("/.git"):
            roots.add(c[:-5])                                  # the main checkout, when this is a worktree
        tracked = {p.replace("\\", "/").lower() for p in files.stdout.split("\0") if p}
        return {"repo_roots": sorted(roots, key=len, reverse=True), "tracked": tracked, "repo_blind": False,
                "top": top.stdout.strip().replace("\\", "/")}
    except (OSError, ValueError, subprocess.SubprocessError):
        return {"repo_roots": [], "tracked": None, "repo_blind": True, "top": ""}


def _norm_dir(p):
    return os.path.normcase(os.path.normpath(p.replace("/", os.sep))) if p else ""


def is_brain_checkout(repo_roots, brain_home):
    """True when the committing checkout belongs to the brain repo: ANY of its roots (repo_context holds the toplevel
    and, for a linked worktree, the common dir's parent, which is the main checkout) is the brain home. Until
    2026-09-23 only the toplevel was compared, so a commit from a LINKED worktree of the brain repo (every
    C:/Users/Owner/.claude-wt/* lane) read as a ThriftyCrew-style repo, and from REFUSE_FROM it would have been
    REFUSED, against D17: the brain warns until Brad sets BRAIN_REFUSE_FROM."""
    b = _norm_dir(brain_home)
    return bool(b) and any(_norm_dir(r) == b for r in (repo_roots or ()))


def estate_context(repo_roots, root=None):
    """{estate_tracked, estate_root, estate_blind} for a commit to a repo that is NOT a ThriftyCrew checkout (W4.5
    step 0). A checkout of the estate - the main one or any linked worktree, whose common dir is the estate's .git -
    already resolves through its own tracked set, so it gets estate_tracked None and no second git call.

    ONE `git -C <root> ls-files` against a DIFFERENT repository, so the eight git repository variables are removed
    for that child only: inside a hook they name the COMMITTING repo, and a child that inherited GIT_DIR or
    GIT_INDEX_FILE would list the committing repo's index under the estate's name. The committing repo's own
    ls-files (repo_context) keeps them, for the opposite reason. A root that cannot be listed is estate_blind,
    never an empty set, and never a refusal on its own: the token is then judged by everything else."""
    root = root or os.environ.get("RECALL_ESTATE_ROOT") or ESTATE_ROOT_DEFAULT
    nr = _norm_dir(root)
    if any(_norm_dir(r) == nr for r in (repo_roots or ())):
        return {"estate_tracked": None, "estate_root": root, "estate_blind": False}
    env = {k: v for k, v in os.environ.items() if k not in GIT_REPO_VARS}
    try:
        r = subprocess.run(["git", "-C", root, "ls-files", "-z"], env=env, capture_output=True, encoding="utf-8",
                           errors="replace", timeout=30)
        if r.returncode != 0:
            raise OSError("git could not list the estate")
        tracked = {p.replace("\\", "/").lower() for p in r.stdout.split("\0") if p}
        return {"estate_tracked": tracked, "estate_root": root, "estate_blind": False}
    except (OSError, ValueError, subprocess.SubprocessError):
        return {"estate_tracked": None, "estate_root": root, "estate_blind": True}


def staged_code_files():
    out = subprocess.run(["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        return None
    return [p for p in out.stdout.splitlines() if p and is_code(p)]


def append_log(path, row):
    try:
        with open(path, "a", encoding="utf-8", newline="\n") as f:
            f.write(json.dumps(row) + "\n")
    except OSError:
        pass


def run_commit_check(msg_path):
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID")
    if not sid:
        return 0                                  # a human or the bot: not judged
    git_dir = subprocess.run(["git", "rev-parse", "--git-dir"], capture_output=True, text=True).stdout.strip()
    if git_dir and os.path.exists(os.path.join(git_dir, "MERGE_HEAD")):
        return 0
    store = home_store()
    if not os.path.isdir(store["skills"]):
        print("store-citation: BLIND - no knowledge store at %s, commit not judged" % store["skills"], file=sys.stderr)
        return 0
    code = staged_code_files()
    if code is None:
        print("store-citation: BLIND - could not list staged files, commit not judged", file=sys.stderr)
        return 0
    with open(msg_path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    text = "\n".join(l for l in text.splitlines() if not l.startswith("#"))
    now = int(time.time())
    today = time.strftime("%Y-%m-%d")
    store.update(repo_context())
    store["repo_is_brain"] = is_brain_checkout(store.get("repo_roots"), os.path.dirname(store["skills"]))
    ec = estate_context(store.get("repo_roots") or ())
    store.update(estate_tracked=ec["estate_tracked"])
    d = judge_message(text, code, store, today, session_searched(store["recall_log"], sid, now))
    d.update(t=now, sid=sid, repo=os.path.basename(os.getcwd()), subject=(text.strip().splitlines() or [""])[0][:120],
             estate_blind=ec["estate_blind"])
    append_log(store["log"], d)
    return emit_verdict(d, len(code))


def emit_verdict(d, n_code, out=None):
    """Print what the commit author needs to see for decision d, and return the hook's exit code."""
    out = out if out is not None else sys.stderr
    if d["verdict"] in ("ok", "exempt"):
        if d["verdict"] == "ok" and d["cited"] and d["backed"] is False:
            print("store-citation: note - Store: line cites files but this session logged no search in the last"
                  " %dh (recorded, not refused)" % BACKING_HOURS, file=out)
        return 0
    if d["verdict"] == "escape-warn":
        # W6.11: its OWN head, and never the BLOCKED text below - an escape form is recorded, not refused.
        print("store-citation: NOTE (escape form, recorded, not refused). This commit changes %d code file(s) and %s."
              % (n_code, d["why"]), file=out)
        print("                Name the store section you used, quote what you searched, or give a Store-Exempt reason"
              " of %d words or more." % EXEMPT_MIN_WORDS, file=out)
        return 0
    if d["verdict"] == "warn":
        head = "WARNING (%s)" % ("the brain repo warns until BRAIN_REFUSE_FROM is set" if d.get("repo_is_brain")
                                 else "refused from %s" % REFUSE_FROM)
    else:
        head = "BLOCKED"
    print("store-citation: %s. This commit changes %d code file(s) and %s." % (head, n_code, d["why"]), file=out)
    if d["unresolved"]:
        print("                not found in the store: %s" % ", ".join(d["unresolved"]), file=out)
    print("                Search first:  C:/Codex/Python312/python.exe C:/Users/Owner/.claude/skills/knowledge-search/search.py \"<terms>\"\n"
          "                then add a line such as:\n"
          "                  Store: database-craft/transactions-and-recovery.md (section 3); memory:ps-null-count-is-one\n"
          "                  Store: .claude/rules/ops-and-gates.md (\"A catch around a native redirect is not a guard\"); lib/atomic-write.ps1 (reused)\n"
          "                  Store: searched \"regex timeout\", nothing applicable\n"
          "                  Store-Exempt: <reason>   (mechanical commits only - logged)", file=out)
    return 1 if d["verdict"] == "refuse" else 0


# ---- self-test --------------------------------------------------------------------------------------

def selftest():
    fails, n = [], 0

    def case(label, cond):
        nonlocal n
        n += 1
        if not cond:
            fails.append(label)

    root = tempfile.mkdtemp(prefix="stc-")
    try:
        store = {"skills": os.path.join(root, "skills"), "memory": os.path.join(root, "mem"),
                 "log": os.path.join(root, "log.jsonl"), "recall_log": os.path.join(root, "recall.jsonl")}
        os.makedirs(os.path.join(store["skills"], "database-craft"))
        os.makedirs(store["memory"])
        open(os.path.join(store["skills"], "database-craft", "transactions.md"), "w").close()
        open(os.path.join(store["memory"], "ps-null.md"), "w").close()
        code = ["ops/x.ps1"]
        warn_day, refuse_day = "2026-09-19", REFUSE_FROM

        d = judge_message("fix\n\nbody\n", code, store, warn_day, None)
        case("MUST FIRE code commit with no Store: line warns before the refuse date", d["verdict"] == "warn")
        d = judge_message("fix\n\nbody\n", code, store, refuse_day, None)
        case("MUST FIRE code commit with no Store: line is refused from the refuse date", d["verdict"] == "refuse")
        d = judge_message("fix\n\nStore: database-craft/nope.md\n", code, store, refuse_day, None)
        case("MUST FIRE a cited file that does not exist is refused", d["verdict"] == "refuse" and d["unresolved"] == ["database-craft/nope.md"])
        d = judge_message("fix\n\nStore: memory:ghost\n", code, store, refuse_day, None)
        case("MUST FIRE a memory that does not exist is refused", d["verdict"] == "refuse")
        store2 = dict(store, memories=[store["memory"], os.path.join(root, "mem2")])
        os.makedirs(store2["memories"][1])
        open(os.path.join(store2["memories"][1], "ps51-bomless.md"), "w").close()
        d = judge_message("fix\n\nStore: memory:ps51-bomless\n", code, store, refuse_day, True)
        case("MUST FIRE founding shape: with only the first store listed, a memo held only by the second is refused",
             d["verdict"] == "refuse" and d["unresolved"] == ["memory:ps51-bomless"])
        d = judge_message("fix\n\nStore: memory:ps51-bomless; [[ps51-bomless]]\n", code, store2, refuse_day, True)
        case("MUST NOT FIRE a memo that exists only in the second store (C--Codex) resolves, both spellings",
             d["verdict"] == "ok" and d["unresolved"] == [] and len(d["cited"]) == 2)
        d = judge_message("fix\n\nStore: memory:in-neither-store\n", code, store2, refuse_day, True)
        case("MUST FIRE with both stores listed, a memo in neither is still refused",
             d["verdict"] == "refuse" and d["unresolved"] == ["memory:in-neither-store"])
        d = judge_message("fix\n\nStore: memory:ps-null\n", code, store2, refuse_day, True)
        case("CLEAN TWIN a memo in the FIRST store still resolves when two are listed", d["verdict"] == "ok" and d["cited"] == ["memory:ps-null"])
        hs = home_store()
        case("CLEAN TWIN home_store lists both launch-root stores, ThriftyCrew first",
             [os.path.basename(os.path.dirname(m)) for m in hs["memories"]] == ["C--Codex-ThriftyCrew", "C--Codex"] and hs["memory"] == hs["memories"][0])
        d = judge_message("fix\n\nStore: I looked around\n", code, store, refuse_day, None)
        case("MUST FIRE a Store: line naming nothing and no search is refused", d["verdict"] == "refuse")
        d = judge_message("fix\n\nStore: database-craft/transactions.md (section 3); memory:ps-null\n", code, store, refuse_day, True)
        case("MUST NOT FIRE resolvable citations pass", d["verdict"] == "ok" and len(d["cited"]) == 2)
        d = judge_message("fix\n\nStore: [[ps-null]]\n", code, store, refuse_day, True)
        case("MUST NOT FIRE a [[memory]] citation resolves", d["verdict"] == "ok")
        d = judge_message('fix\n\nStore: searched "regex timeout", nothing applicable\n', code, store, refuse_day, True)
        case("MUST NOT FIRE an explicit nothing-applicable search passes", d["verdict"] == "ok")
        d = judge_message("data\n", [], store, refuse_day, None)
        case("MUST NOT FIRE a commit with no code is not judged", d["verdict"] == "ok")
        d = judge_message("rename\n\nStore-Exempt: pure file rename\n", code, store, refuse_day, None)
        case("MUST NOT FIRE Store-Exempt with a reason of exactly three words (the bar, EXEMPT_MIN_WORDS) passes and records it",
             d["verdict"] == "exempt" and d["why"] == "pure file rename")
        case("CLEAN TWIN code detection: a .ps1 is code, a board output is not, a hook is",
             is_code("ops/x.ps1") and not is_code("grocery/out/a.py") and is_code("ops/hooks/commit-msg") and not is_code("design/PLAN-x.md"))

        with open(store["recall_log"], "w") as f:
            f.write(json.dumps({"t": 1000, "ev": "search", "sid": "s1"}) + "\n")
            f.write(json.dumps({"t": 1000, "ev": "open", "sid": "s2"}) + "\n")
            f.write(json.dumps({"t": 1000, "ev": "search", "sid": "s3x"}) + "\n")
        case("MUST FIRE a logged search in the same session backs the line", session_searched(store["recall_log"], "s1", 2000) is True)
        case("MUST NOT FIRE another session's search, or an open, backs nothing", session_searched(store["recall_log"], "s2", 2000) is False)
        case("MUST NOT FIRE a session id that is only a SUBSTRING of a searching session's backs nothing",
             session_searched(store["recall_log"], "s3", 2000) is False)
        case("MUST NOT FIRE a search older than the window backs nothing", session_searched(store["recall_log"], "s1", 1000 + BACKING_HOURS * 3600 + 1) is False)
        case("CLEAN TWIN an unreadable log is None, never False", session_searched(os.path.join(root, "absent"), "s1", 2000) is None)

        dd = os.path.join(root, "design")
        os.makedirs(dd)
        with open(os.path.join(dd, "PLAN-old-2026-09-01.md"), "w") as f:
            f.write("# old\n")
        with open(os.path.join(dd, "PLAN-new-%s.md" % PLAN_CUTOFF), "w") as f:
            f.write("# new\n\n## Knowledge consulted\n\n## Next\n")
        with open(os.path.join(dd, "MEASURE-good-%s.md" % PLAN_CUTOFF), "w") as f:
            f.write("# m\n\n## Knowledge consulted\n\nsearched x: nothing applicable\n")
        judged, missing = plan_findings(dd)
        case("MUST FIRE a new plan whose section is EMPTY is missing", missing == ["PLAN-new-%s.md" % PLAN_CUTOFF])
        case("MUST NOT FIRE a plan dated before the cutoff is not judged", "PLAN-old-2026-09-01.md" not in judged)
        case("CLEAN TWIN a filled section on a MEASURE doc is judged and passes", "MEASURE-good-%s.md" % PLAN_CUTOFF in judged and len(judged) == 2)

        # ---- W5.3: every analysis record prefix is judged, not only PLAN and MEASURE ----
        ad = os.path.join(root, "design-analysis")
        os.makedirs(ad)
        for name, body in (("RCA-empty-%s.md" % PLAN_CUTOFF, "# rca\n"),
                           ("FINDINGS-empty-%s.md" % PLAN_CUTOFF, "# f\n\n## Knowledge consulted\n\n## Next\n"),
                           ("REVIEW-good-%s.md" % PLAN_CUTOFF, "# r\n\n## Knowledge consulted\n\nmemory:ps-null\n"),
                           ("NOTES-other-prefix-%s.md" % PLAN_CUTOFF, "# not an analysis record\n")):
            with open(os.path.join(ad, name), "w") as f:
                f.write(body)
        real_plan = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "design",
                                 "PLAN-brain-consults-on-code-and-analysis-2026-09-22.md")
        if os.path.isfile(real_plan):
            with open(real_plan, "rb") as f:
                rp = f.read()
            with open(os.path.join(ad, os.path.basename(real_plan)), "wb") as f:
                f.write(rp)
        aj, am = plan_findings(ad)
        case("MUST FIRE an RCA record dated on the cutoff with no section is judged and missing (a prefix W5.3 added)",
             "RCA-empty-%s.md" % PLAN_CUTOFF in aj and "RCA-empty-%s.md" % PLAN_CUTOFF in am)
        case("MUST FIRE a FINDINGS record whose section is empty is missing (FINDINGS, not cut short at FINDING)",
             "FINDINGS-empty-%s.md" % PLAN_CUTOFF in am)
        case("MUST NOT FIRE a dated file whose prefix is not an analysis record is not judged",
             not any(n.startswith("NOTES-") for n in aj))
        case("CLEAN TWIN an existing PLAN doc (this plan, copied byte for byte) and a filled REVIEW still pass the audit",
             os.path.basename(real_plan) in aj and os.path.basename(real_plan) not in am
             and "REVIEW-good-%s.md" % PLAN_CUTOFF in aj and "REVIEW-good-%s.md" % PLAN_CUTOFF not in am)
        case("CLEAN TWIN ANALYSIS_RECORD_PREFIXES is the ten the plan names, in its order (recall_core mirrors this tuple)",
             ANALYSIS_RECORD_PREFIXES == ("PLAN", "MEASURE", "EVAL", "TRIAL", "RCA", "REVIEW", "AUDIT", "FINDING",
                                          "FINDINGS", "PROBE"))

        # ---- W0.1: the estate's own knowledge resolves (design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md) ----
        rroot = "C:/Temp/Repo"
        rstore = dict(store, tracked={".claude/rules/r.md", "lib/x.ps1", "ops/x.ps1", "design/plan-a-2026-09-22.md"},
                      repo_roots=[rroot], repo_blind=False)
        d = judge_message('fix\n\nStore: .claude/rules/r.md ("a rule")\n', code, rstore, refuse_day, True)
        case("MUST NOT FIRE a tracked rules file resolves as kind rules, and naming its bullet leaves no rules_without_section",
             d["verdict"] == "ok" and d["cited_kinds"] == ["rules"] and d["rules_without_section"] == [])
        d = judge_message("fix\n\nStore: lib\\x.ps1 (reused)\n", code, rstore, refuse_day, True)
        case("MUST NOT FIRE a backslash lib path is normalised BEFORE extraction and resolves as machinery",
             d["verdict"] == "ok" and d["cited"] == ["lib/x.ps1"] and d["cited_kinds"] == ["machinery"])
        d = judge_message("fix\n\nStore: r.md\n", code, rstore, refuse_day, True)
        case("MUST NOT FIRE a bare rules file name falls back to .claude/rules, and is recorded as citing no bullet",
             d["verdict"] == "ok" and d["cited_kinds"] == ["rules"] and d["rules_without_section"] == ["r.md"])
        d = judge_message("fix\n\nStore: .claude/rules/nope.md\n", code, rstore, refuse_day, True)
        case("MUST FIRE a rules path the checkout does not track is refused on the refuse date",
             d["verdict"] == "refuse" and d["unresolved"] == [".claude/rules/nope.md"])
        disk = os.path.join(root, "repo")
        os.makedirs(os.path.join(disk, "lib"))
        open(os.path.join(disk, "lib", "y.ps1"), "w").close()
        here = os.getcwd()
        try:
            os.chdir(disk)
            d = judge_message("fix\n\nStore: lib/y.ps1\n", code, dict(rstore, repo_roots=[disk]), refuse_day, True)
        finally:
            os.chdir(here)
        case("MUST FIRE a file on disk that git does not track is refused (the tracked test, not os.path.exists)",
             d["verdict"] == "refuse" and d["unresolved"] == ["lib/y.ps1"])
        d = judge_message("fix\n\nStore: ops/x.ps1\n", code, rstore, refuse_day, True)
        case("MUST FIRE a line citing only the staged code file itself names nothing, and is refused",
             d["verdict"] == "refuse" and d["self_cited"] == ["ops/x.ps1"] and d["cited"] == [])
        d = judge_message("fix\n\nStore: C:\\Users\\Owner\\.claude\\skills\\database-craft\\transactions.md; "
                          "C:\\Users\\Owner\\.claude\\skills\\database-craft\\transactions.md\n", code, rstore, refuse_day, True)
        case("MUST NOT FIRE an absolute store path resolves, including a second one after ';' (a prefix at every token start)",
             d["verdict"] == "ok" and d["cited"] == ["database-craft/transactions.md"] * 2 and d["cited_kinds"] == ["store"])
        d = judge_message("fix\n\nStore: C:\\Temp\\Repo\\.claude\\rules\\r.md\n", code, rstore, refuse_day, True)
        case("MUST NOT FIRE an absolute repo path is made repo-relative and resolves",
             d["verdict"] == "ok" and d["cited"] == [".claude/rules/r.md"])
        l93 = "Store: reliability-craft/applies-here.md (The scoreboard: audit-alert-precision.ps1 is the"
        lce = ('Store: searched "not-carried recipe discard", nothing applicable in skills; '
               "memory:no-gated-hold-for-a-pre-state-machine-recipe (superseded by hold-recipe.ps1), "
               "design/PLAN-carriage-gate-2026-08-22.md section 5")
        for sha, line in (("93ef5df50", l93), ("ce642822d", lce)):
            d = judge_message("fix\n\n" + line + "\n", code, rstore, refuse_day, True)
            case("MUST NOT FIRE %s's Store: line, verbatim: a bare .ps1 basename in its prose is not extracted" % sha,
                 not any(c.endswith(".ps1") for c in d["cited"]))
        d = judge_message("fix\n\nStore: memory:ps-null\n", code, rstore, refuse_day, True)
        case("CLEAN TWIN a memory citation still resolves beside a repo context", d["verdict"] == "ok" and d["cited_kinds"] == ["memory"])
        d = judge_message("fix\n\nStore: .claude/rules/r.md\n", code, dict(store, tracked=None, repo_roots=[], repo_blind=True), refuse_day, True)
        case("CLEAN TWIN an unlistable repo accepts a repo citation and records repo_blind (a could-not-look never refuses)",
             d["verdict"] == "ok" and d["repo_blind"] is True and d["cited_kinds"] == ["repo_blind"])

        # ---- a section title in quotes or parentheses is not a citation (strip_section_titles) ----
        os.makedirs(os.path.join(store["skills"], "course"))
        open(os.path.join(store["skills"], "course", "CONSOLIDATE.md"), "w").close()
        title = 'Store: course/CONSOLIDATE.md ("Everything about `applies-here.md`")'
        d = judge_message("fix\n\n" + title + "\n", code, store, refuse_day, True)
        case("MUST NOT FIRE the brain lanes' line, verbatim: a bare .md inside a quoted, parenthesised section title is not cited",
             d["verdict"] == "ok" and d["cited"] == ["course/CONSOLIDATE.md"] and d["unresolved"] == [])
        d = judge_message("fix\n\n" + title + "; r.md\n", code, rstore, refuse_day, True)
        case("CLEAN TWIN a real bare citation after the title still resolves (r.md, through the rules fallback)",
             d["verdict"] == "ok" and d["cited"] == ["course/CONSOLIDATE.md", "r.md"] and "rules" in d["cited_kinds"])
        d = judge_message("fix\n\n" + title + "; ghost.md\n", code, rstore, refuse_day, True)
        case("MUST FIRE an unresolvable bare .md OUTSIDE the title is still refused on the refuse date",
             d["verdict"] == "refuse" and d["unresolved"] == ["ghost.md"])
        esc = 'Store: course/CONSOLIDATE.md, section "the estate\'s answer to \\"a `b.md` c\\""; memory:ps-null'
        d = judge_message("fix\n\n" + esc + "\n", code, store, refuse_day, True)
        case("MUST NOT FIRE a double-quoted title holding escaped quotes is blanked whole, and the memory after it is cited",
             d["verdict"] == "ok" and d["cited"] == ["course/CONSOLIDATE.md", "memory:ps-null"])
        sq = "Store: course/CONSOLIDATE.md section 'Brad's b.md list'; r.md"
        d = judge_message("fix\n\n" + sq + "\n", code, rstore, refuse_day, True)
        case("MUST NOT FIRE a single-quoted title is not cut short by the apostrophe inside it (Brad's)",
             d["verdict"] == "ok" and d["cited"] == ["course/CONSOLIDATE.md", "r.md"])
        d = judge_message("fix\n\nStore: reused (lib/x.ps1)\n", code, rstore, refuse_day, True)
        case("CLEAN TWIN a parenthesis that does not follow a citation keeps its citation, which resolves",
             d["verdict"] == "ok" and d["cited"] == ["lib/x.ps1"] and d["cited_kinds"] == ["machinery"])
        d = judge_message('fix\n\nStore: searched "lib/zz.ps1 retry", nothing applicable\n', code, rstore, refuse_day, True)
        case("MUST NOT FIRE a path inside a quoted search term is not a citation, and the quoted claim passes",
             d["verdict"] == "ok" and d["cited"] == [] and d["escape"] is None)
        d = judge_message("fix\n\nStore: course/CONSOLIDATE.md (Everything about applies-here.md, wrapped\n", code, store, refuse_day, True)
        case("MUST NOT FIRE a title left open by a wrapped Store: line is blanked to the end of that line",
             d["verdict"] == "ok" and d["cited"] == ["course/CONSOLIDATE.md"])

        # The real git path, on a temp repo. The eight repository variables are removed from the FIXTURE's child
        # env only (ops-and-gates: a fixture that builds a temp repo clears them); repo_context itself must keep
        # them, because under a pathspec commit GIT_INDEX_FILE names the index being committed.
        genv = {k: v for k, v in os.environ.items() if k not in (
            "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX", "GIT_NAMESPACE")}
        genv["GIT_CEILING_DIRECTORIES"] = root
        grepo = os.path.join(root, "gitrepo")
        os.makedirs(os.path.join(grepo, ".claude", "rules"))
        os.makedirs(os.path.join(grepo, "lib"))
        for rel in (".claude/rules/r.md", "lib/x.ps1"):
            with open(os.path.join(grepo, rel), "w") as f:
                f.write("x\n")
        for args in (["init", "-q"], ["add", "--", ".claude/rules/r.md", "lib/x.ps1"],
                     ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base"]):
            subprocess.run(["git"] + args, cwd=grepo, env=genv, capture_output=True, text=True)
        ctx = repo_context(cwd=grepo, env=genv)
        case("CLEAN TWIN repo_context reads a real repo's tracked set and its root",
             ctx["repo_blind"] is False and ctx["tracked"] is not None
             and {".claude/rules/r.md", "lib/x.ps1"} <= ctx["tracked"] and len(ctx["repo_roots"]) >= 1)
        os.makedirs(os.path.join(root, "not-a-repo"))
        ctx2 = repo_context(cwd=os.path.join(root, "not-a-repo"), env=genv)
        case("MUST FIRE a directory that is not a repo reads as repo_blind, never as an empty tracked set",
             ctx2["repo_blind"] is True and ctx2["tracked"] is None)

        # ---- W0.2: the SHARED commit-msg hook, driven by a real `git commit` in a temp repo ----
        # core.hooksPath points at a temp copy of ops/hooks/commit-msg, so git runs it the way it runs it live
        # and nothing installed on this box is touched. USERPROFILE is a temp home holding an empty
        # .claude/skills, which keeps both the BLIND-no-store branch and the live decision log out of the case.
        # No date override reaches this path: the verdicts asserted here hold on any day.
        hooks_dir = os.path.join(root, "hooks")
        os.makedirs(hooks_dir)
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "hooks", "commit-msg"), "rb") as f:
            hook_bytes = f.read().replace(b"\r\n", b"\n")
        with open(os.path.join(hooks_dir, "commit-msg"), "wb") as f:
            f.write(hook_bytes)
        thome = os.path.join(root, "home")
        os.makedirs(os.path.join(thome, ".claude", "skills"))
        henv = dict(genv, CLAUDE_CODE_SESSION_ID="stc-fixture-session", USERPROFILE=thome)

        def hook_commit(repo, rel, body, msg, tag):
            with open(os.path.join(repo, rel), "w", newline="\n") as f:
                f.write(body)
            subprocess.run(["git", "add", "--", rel], cwd=repo, env=henv, capture_output=True, text=True)
            mp = os.path.join(root, "msg-%s.txt" % tag)
            with open(mp, "w", encoding="utf-8", newline="\n") as f:
                f.write(msg)
            r = subprocess.run(["git", "-c", "core.hooksPath=" + hooks_dir, "-c", "user.name=t", "-c", "user.email=t@t",
                                "commit", "-q", "-F", mp], cwd=repo, env=henv, capture_output=True, encoding="utf-8",
                               errors="replace", timeout=180)
            head = subprocess.run(["git", "log", "-1", "--format=%s"], cwd=repo, env=henv, capture_output=True,
                                  encoding="utf-8", errors="replace").stdout.strip()
            return r, head

        hr, hhead = hook_commit(grepo, "lib/x.ps1", "y\n", 'blind case\n\nStore: .claude/rules/r.md ("a rule")\n', "blind")
        case("MUST FIRE a checkout with no ops/store_citation.py prints the BLIND line on stderr, exits 0 and the commit lands",
             hr.returncode == 0 and hhead == "blind case" and "store-citation: BLIND - this checkout has no "
             + "ops/store_citation.py; the commit is not judged" in (hr.stderr or ""))
        hrepo = os.path.join(root, "hookrepo")
        os.makedirs(os.path.join(hrepo, ".claude", "rules"))
        os.makedirs(os.path.join(hrepo, "lib"))
        os.makedirs(os.path.join(hrepo, "ops"))
        with open(os.path.abspath(__file__), "rb") as f:
            me = f.read().replace(b"\r\n", b"\n")
        with open(os.path.join(hrepo, "ops", "store_citation.py"), "wb") as f:
            f.write(me)
        for rel in (".claude/rules/r.md", "lib/x.ps1"):
            with open(os.path.join(hrepo, rel), "w", newline="\n") as f:
                f.write("x\n")
        for args in (["init", "-q"], ["add", "--", ".claude/rules/r.md", "lib/x.ps1", "ops/store_citation.py"],
                     ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base"]):
            subprocess.run(["git"] + args, cwd=hrepo, env=genv, capture_output=True, text=True)
        hr2, hhead2 = hook_commit(hrepo, "lib/x.ps1", "z\n", 'cites a rule\n\nStore: .claude/rules/r.md ("a rule")\n', "ok")
        hlog = os.path.join(thome, ".claude", "store-citation-log.jsonl")
        hrows = []
        if os.path.isfile(hlog):
            with open(hlog, encoding="utf-8", errors="replace") as f:
                hrows = [json.loads(l) for l in f if l.strip()]
        case("CLEAN TWIN with the script present the hook reaches store_citation: the commit lands and exactly one ok row is logged",
             hr2.returncode == 0 and hhead2 == "cites a rule" and len(hrows) == 1 and hrows[0].get("verdict") == "ok"
             and hrows[0].get("cited") == [".claude/rules/r.md"])

        # ---- W4.5 step 0: a commit to the BRAIN repo resolves estate tokens, and warns until BRAIN_REFUSE_FROM ----
        # A temp estate repo tracks design/PLAN-x.md and .claude/rules/r.md; a temp brain repo IS the temp home's
        # .claude, so repo_is_brain is decided the way run_commit_check decides it. RECALL_ESTATE_ROOT names the temp
        # estate, so the live C:\Codex\ThriftyCrew is never listed by a fixture.
        erepo = os.path.join(root, "estate")
        os.makedirs(os.path.join(erepo, "design"))
        os.makedirs(os.path.join(erepo, ".claude", "rules"))
        for rel in ("design/PLAN-x.md", ".claude/rules/r.md"):
            with open(os.path.join(erepo, rel), "w", newline="\n") as f:
                f.write("x\n")
        for args in (["init", "-q"], ["add", "--", "design/PLAN-x.md", ".claude/rules/r.md"],
                     ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "estate"]):
            subprocess.run(["git"] + args, cwd=erepo, env=genv, capture_output=True, text=True)
        bhome = os.path.join(root, "bhome")
        brepo = os.path.join(bhome, ".claude")
        os.makedirs(os.path.join(brepo, "skills"))
        with open(os.path.join(brepo, "skills", "x.py"), "w", newline="\n") as f:
            f.write("x = 1\n")
        for args in (["init", "-q"], ["add", "--", "skills/x.py"],
                     ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "brain base"]):
            subprocess.run(["git"] + args, cwd=brepo, env=genv, capture_output=True, text=True)
        with open(os.path.join(brepo, "skills", "x.py"), "w", newline="\n") as f:
            f.write("x = 2\n")
        subprocess.run(["git", "add", "--", "skills/x.py"], cwd=brepo, env=genv, capture_output=True, text=True)
        benv = dict(genv, CLAUDE_CODE_SESSION_ID="stc-brain-fixture", USERPROFILE=bhome, RECALL_ESTATE_ROOT=erepo)

        def brain_check(msg, tag, cwd=None):
            mp = os.path.join(root, "bmsg-%s.txt" % tag)
            with open(mp, "w", encoding="utf-8", newline="\n") as f:
                f.write(msg)
            r = subprocess.run([sys.executable, os.path.abspath(__file__), "--commit-msg", mp], cwd=cwd or brepo, env=benv,
                               capture_output=True, encoding="utf-8", errors="replace", timeout=180)
            blog = os.path.join(brepo, "store-citation-log.jsonl")
            rows = []
            if os.path.isfile(blog):
                with open(blog, encoding="utf-8", errors="replace") as f:
                    rows = [json.loads(l) for l in f if l.strip()]
            return r, (rows[-1] if rows else {}), len(rows)

        br, brow, bn = brain_check("brain fix\n\nbody\n", "none")
        case("CLEAN TWIN with BRAIN_REFUSE_FROM None a brain commit with no Store: line WARNS, exits 0, and is logged as a brain warn",
             BRAIN_REFUSE_FROM is None and br.returncode == 0 and "WARNING (the brain repo warns" in (br.stderr or "")
             and bn == 1 and brow.get("verdict") == "warn" and brow.get("repo_is_brain") is True)
        br2, brow2, bn2 = brain_check('brain fix\n\nStore: design/PLAN-x.md; .claude/rules/r.md ("a rule")\n', "estate")
        case("MUST NOT FIRE a brain commit citing design/PLAN-x.md and .claude/rules/r.md, tracked only in the estate, passes (resolved_in estate)",
             br2.returncode == 0 and bn2 == 2 and brow2.get("verdict") == "ok"
             and brow2.get("resolved_in") == {"design/PLAN-x.md": "estate", ".claude/rules/r.md": "estate"})
        ectx = estate_context([brepo.replace("\\", "/")], root=erepo)
        bstore = dict(store, tracked={"skills/x.py"}, repo_roots=[brepo], repo_blind=False, repo_is_brain=True,
                      estate_tracked=ectx["estate_tracked"])
        saved_brain = BRAIN_REFUSE_FROM
        try:
            globals()["BRAIN_REFUSE_FROM"] = "2026-09-01"
            d = judge_message("brain fix\n\nStore: design/nope.md\n", ["skills/x.py"], bstore, "2026-09-02", True)
            d_ok = judge_message("brain fix\n\nStore: design/PLAN-x.md\n", ["skills/x.py"], bstore, "2026-09-02", True)
        finally:
            globals()["BRAIN_REFUSE_FROM"] = saved_brain
        case("MUST FIRE once BRAIN_REFUSE_FROM is set and passed, a brain token tracked in neither repo is refused (and an estate one still passes)",
             d["verdict"] == "refuse" and d["unresolved"] == ["design/nope.md"] and d_ok["verdict"] == "ok")
        d = judge_message("brain fix\n\nbody\n", ["skills/x.py"], bstore, "2026-09-30", None)
        d_tc = judge_message("fix\n\nbody\n", code, dict(bstore, repo_is_brain=False), "2026-09-30", None)
        case("CLEAN TWIN past REFUSE_FROM, with BRAIN_REFUSE_FROM None, a brain commit with no Store: line still WARNS while a ThriftyCrew one refuses",
             BRAIN_REFUSE_FROM is None and d["verdict"] == "warn" and d["mode"] == "warn" and d_tc["verdict"] == "refuse")
        ectx_self = estate_context([erepo.replace("\\", "/")], root=erepo)
        case("CLEAN TWIN a ThriftyCrew checkout (its roots include the estate root) resolves through its own set: no estate listing",
             ectx_self["estate_tracked"] is None and ectx_self["estate_blind"] is False
             and ectx["estate_tracked"] is not None and "design/plan-x.md" in ectx["estate_tracked"])
        ectx_gone = estate_context([brepo], root=os.path.join(root, "no-such-estate"))
        case("MUST FIRE an estate root that cannot be listed is estate_blind, never an empty tracked set",
             ectx_gone["estate_blind"] is True and ectx_gone["estate_tracked"] is None)

        # ---- a LINKED worktree of the brain repo is the brain (the C:/Users/Owner/.claude-wt/* lanes) ----
        # Its toplevel is the worktree, never the brain home, so the brain is recognised through the common root
        # repo_context already holds. The worktree is cut from the temp brain repo; nothing live is touched.
        bwt = os.path.join(root, "bwt")
        subprocess.run(["git", "worktree", "add", "-q", "-b", "lane", bwt], cwd=brepo, env=genv, capture_output=True, text=True)
        with open(os.path.join(bwt, "skills", "x.py"), "w", newline="\n") as f:
            f.write("x = 3\n")
        subprocess.run(["git", "add", "--", "skills/x.py"], cwd=bwt, env=genv, capture_output=True, text=True)
        wr, wrow, wn = brain_check("brain lane fix\n\nbody\n", "worktree", cwd=bwt)
        case("MUST FIRE a commit from a LINKED worktree of the brain repo is judged as the brain (repo_is_brain, the brain's warn head, exit 0)",
             wr.returncode == 0 and "WARNING (the brain repo warns" in (wr.stderr or "") and wn == 3
             and wrow.get("repo_is_brain") is True and wrow.get("verdict") == "warn")
        ewt = os.path.join(root, "ewt")
        subprocess.run(["git", "worktree", "add", "-q", "-b", "lane", ewt], cwd=erepo, env=genv, capture_output=True, text=True)
        bctx = repo_context(cwd=bwt, env=genv)
        ewctx = repo_context(cwd=ewt, env=genv)
        case("MUST NOT FIRE a linked worktree of a repo that is NOT the brain is not the brain, while the brain's own worktree is",
             not is_brain_checkout(ewctx["repo_roots"], brepo) and is_brain_checkout(bctx["repo_roots"], brepo)
             and len(ewctx["repo_roots"]) == 2 and not is_brain_checkout([], brepo))

        # ---- W6.11: the cheap escapes are recorded as escape-warn, never through the refuse mode ----
        open(os.path.join(root, "CLAUDE.md"), "w").close()                       # the ~/.claude store base holds CLAUDE.md
        open(os.path.join(store["memory"], "MEMORY.md"), "w").close()
        os.makedirs(os.path.join(store["skills"], "knowledge-search"))
        open(os.path.join(store["skills"], "knowledge-search", "SKILL.md"), "w").close()
        open(os.path.join(store["skills"], "database-craft", "SKILL.md"), "w").close()
        late = "2026-09-30"
        d = judge_message("fix\n\nStore: CLAUDE.md\n", code, store, late, True)
        eo = __import__("io").StringIO()
        erc = emit_verdict(d, 1, out=eo)
        case("CLEAN TWIN on 2026-09-30 'Store: CLAUDE.md' alone is escape-warn, exits 0, prints the NOTE head and never BLOCKED",
             ESCAPES_REFUSE_FROM is None and d["verdict"] == "escape-warn" and d["escape"] == "index-only" and erc == 0
             and "NOTE (escape form, recorded, not refused)" in eo.getvalue() and "BLOCKED" not in eo.getvalue())
        saved_esc = ESCAPES_REFUSE_FROM
        try:
            globals()["ESCAPES_REFUSE_FROM"] = "2026-09-01"
            d = judge_message("fix\n\nStore: CLAUDE.md\n", code, store, late, True)
        finally:
            globals()["ESCAPES_REFUSE_FROM"] = saved_esc
        eo = __import__("io").StringIO()
        erc = emit_verdict(d, 1, out=eo)
        case("MUST FIRE with ESCAPES_REFUSE_FROM set to a past date the same line refuses (exit 1, BLOCKED)",
             d["verdict"] == "refuse" and erc == 1 and "BLOCKED" in eo.getvalue())
        d = judge_message("fix\n\nbody\n", code, store, late, None)
        case("CLEAN TWIN on 2026-09-30 a code commit with no Store: line still refuses (the mode, not an escape)",
             d["verdict"] == "refuse" and d["escape"] is None)
        d = judge_message("fix\n\nStore: searched regex timeout, nothing applicable\n", code, store, late, True)
        case("MUST FIRE a nothing-applicable line with no quoted search term is escape-warn (unquoted-search)",
             d["verdict"] == "escape-warn" and d["escape"] == "unquoted-search")
        d = judge_message("fix\n\nStore: searched \u201cregex timeout\u201d, nothing further applicable\n", code, store, late, True)
        case("MUST NOT FIRE a smart-quoted search with the observed 'nothing further applicable' passes",
             d["verdict"] == "ok" and d["escape"] is None)
        d = judge_message("rename\n\nStore-Exempt: pure rename\n", code, store, late, None)
        case("MUST FIRE a Store-Exempt reason of two words, one step under the bar of three, is escape-warn (short-exempt)",
             d["verdict"] == "escape-warn" and d["escape"] == "short-exempt" and d["why"] == "pure rename")
        d = judge_message("fix\n\nStore: CLAUDE.md; database-craft/transactions.md (section 3)\n", code, store, late, True)
        case("MUST NOT FIRE an index file cited beside a real store file passes", d["verdict"] == "ok" and d["escape"] is None)
        d = judge_message("fix\n\nStore: database-craft/SKILL.md\n", code, store, late, True)
        case("MUST NOT FIRE another skill's SKILL.md is a subject, not an index file", d["verdict"] == "ok" and d["escape"] is None)
        d = judge_message("fix\n\nStore: memory:MEMORY\n", code, store, late, True)
        case("MUST FIRE memory:MEMORY alone is an index-only citation", d["verdict"] == "escape-warn" and d["escape"] == "index-only")
        d = judge_message("fix\n\nStore: knowledge-search/SKILL.md\n", code, store, late, True)
        case("MUST FIRE knowledge-search/SKILL.md alone is an index-only citation", d["verdict"] == "escape-warn" and d["escape"] == "index-only")
    finally:
        import shutil
        shutil.rmtree(root, ignore_errors=True)

    for f in fails:
        print("  FAIL  " + f)
    expected = 71
    if n != expected:
        fails.append("ran %d cases, expected %d" % (n, expected))
        print("  FAIL  ran %d cases, expected %d" % (n, expected))
    print("store_citation self-test: %s (cases=%d failures=%d)" % ("pass" if not fails else "FAIL", n, len(fails)))
    return 1 if fails else 0


def main(argv):
    if "--selftest" in argv:
        return selftest()
    if "--commit-msg" in argv:
        i = argv.index("--commit-msg")
        return run_commit_check(argv[i + 1]) if i + 1 < len(argv) else 0
    return run_plan_audit(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
