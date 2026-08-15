#!/usr/bin/env bash
# sync-main.sh - keep the MAIN working tree's `main` at origin/main. Never behind, ever.
#
# WHY THIS EXISTS. Work happens in git worktrees under .claude/worktrees/. `main` is checked out in the
# main tree, and git refuses to let a worktree move a branch ref another worktree holds:
#
#     fatal: cannot force update the branch 'main' used by worktree at 'C:/Codex/ThriftyCrew'
#
# So a worktree ships with `git push origin HEAD:main`, which writes the REMOTE ref and nothing else.
# The local `main` pointer never learns about it and silently falls behind - three commits on
# 2026-08-05 before anyone looked. Nothing had forked; `main` was just stale. But the nightly
# grocery/run-daily-local.ps1 commits INTO that tree, and its recovery path rebases with `-X theirs`
# and autostashes, so starting from a stale base is how local edits get quietly resolved away.
#
# This runs after any `git push` and at session start, and fast-forwards the main tree.
#
# IT ONLY EVER FAST-FORWARDS. --ff-only cannot merge, rebase, or create a commit: if `main` has
# anything origin/main does not, this does nothing and says so. It is a pointer fix, never a
# reconciliation - reconciling divergent history is a decision a person makes.
set -u

MAIN="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" 2>/dev/null)"
[ -n "${MAIN:-}" ] && [ -d "$MAIN" ] || exit 0

# Only touch the tree when it is actually sitting on main. If someone checked out another branch
# there, fast-forwarding it to origin/main would be a surprise, not a fix.
BR="$(git -C "$MAIN" rev-parse --abbrev-ref HEAD 2>/dev/null)" || exit 0
[ "$BR" = "main" ] || exit 0

git -C "$MAIN" fetch origin main --quiet 2>/dev/null || exit 0

BEHIND="$(git -C "$MAIN" rev-list --count HEAD..origin/main 2>/dev/null)" || exit 0
AHEAD="$(git -C "$MAIN" rev-list --count origin/main..HEAD 2>/dev/null)" || exit 0
[ "${BEHIND:-0}" -gt 0 ] 2>/dev/null || exit 0

# Ahead AND behind is a real fork. Say so and change nothing - --ff-only would refuse anyway, but
# failing loudly beats a generic "could not fast-forward".
if [ "${AHEAD:-0}" -gt 0 ] 2>/dev/null; then
  printf '{"systemMessage":"main has DIVERGED from origin/main (%s ahead, %s behind) in %s - not touched. Reconcile by hand."}\n' "$AHEAD" "$BEHIND" "$MAIN"
  exit 0
fi

if git -C "$MAIN" merge --ff-only origin/main --quiet 2>/dev/null; then
  printf '{"systemMessage":"main working tree fast-forwarded %s commit(s) to origin/main"}\n' "$BEHIND"
else
  printf '{"systemMessage":"main working tree is %s commit(s) behind origin/main and would not fast-forward (uncommitted changes in the way). Fix in %s."}\n' "$BEHIND" "$MAIN"
fi
exit 0
