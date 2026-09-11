# git-repo-env.ps1 - the repository environment a git hook hands its children, and the one call that clears it.
#
# THE HAZARD, MEASURED. Git exports GIT_DIR to a hook when the command comes from a LINKED worktree and exports
# none from the main checkout: pre-push on 2026-09-10, pre-commit on 2026-09-11, both on git 2.54 in a sandbox.
# Everything the hook spawns inherits it, and GIT_DIR overrides -C. Inside such a hook
# `git -C <temp> config user.name X` wrote X into the MAIN repository's config, and `git init <temp>` turned the
# shared repository bare; on 2026-09-10 that took `git status` away from every checkout on the box. pre-commit
# also exports GIT_INDEX_FILE (`.git/index`, or a lock file for `commit -a` and `commit -- <paths>`), so under
# that hook a temp-repo `git -C <temp> add` writes the index of the commit being made.
#
# THREE LAYERS CALL FOR THE SAME LIST. ops\hooks\pre-push unsets it in sh before it runs the gate; ops\run-gates.ps1
# and ops\prepush-test-auditors.ps1 clear it for every other caller (fixtured in ops\test-prepush-hook.ps1); and
# every script that builds a temp repo clears it before its first `git init`, which
# ops\audit-git-fixture-env.ps1 checks on every push. ops\hooks\pre-commit is the exception: it must keep
# GIT_INDEX_FILE, and says why.
#
# WHY A FIXTURE SCRUBS RATHER THAN REFUSES (decided 2026-09-11). Refusing to run when GIT_DIR is set was the
# other option, and it loses on three counts:
#   1. The variables are not always a leak. pre-commit's checkers need GIT_INDEX_FILE to see a partial commit,
#      and lib\pipeline-commit.ps1, grocery\push-data.ps1 and grocery\capture-run.ps1 set it on purpose for a
#      private index. A refusal keyed on the environment cannot tell those from the 2026-09-10 case.
#   2. A refusal exits 3, and run-gates and pre-push read 3 as COULD NOT EVALUATE, so it would block a push over
#      the caller's environment rather than over anything wrong in the tree.
#   3. A fixture names its temp repo by path and needs none of these variables, so removing them costs nothing
#      and makes `git -C <temp>` mean <temp> whoever spawned the process.
# What a refusal would have bought is noticing that a CALLER leaked. The hook and run-gates layers are fixtured
# for exactly that, so the fixture layer does not have to carry it too.
#
# ONLY IN A PROCESS THAT OWNS ITS ENVIRONMENT. This removes the variables from the whole process. A library that
# is dot-sourced into a live committer calls it inside its own self-test branch, never at load time, or it strips
# the private index out of the committer that loaded it.
#
# NO param() BLOCK, DELIBERATELY - same rule as lib\guard-contract.ps1: dot-sourcing runs it in the caller's scope.

function Clear-TcGitRepoEnv {
  # The variables that tell git WHICH repository, work tree, index, object store, ref namespace or path prefix
  # to use - githooks(5) names clearing them as what a hook must do before it runs git against another
  # repository. GIT_EDITOR, GIT_AUTHOR_* and the rest describe the COMMAND, not the repository, and stay.
  foreach ($v in @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR', 'GIT_OBJECT_DIRECTORY',
                   'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_PREFIX', 'GIT_NAMESPACE')) {
    if (Test-Path -LiteralPath ("Env:\" + $v)) { Remove-Item -LiteralPath ("Env:\" + $v) }
  }
}
