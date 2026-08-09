# Grocery platform operator contract

The v3 Worker is the only production write boundary. Do not write D1 or R2 from a capture client, workflow,
or maintenance script. Use `pnpm tc help` and the authenticated `/internal/*` API.

Before changing pricing behavior:

1. Read `docs/IMPLEMENTATION-CONTRACT.md` and `docs/lessons.md`.
2. Add or update a frozen must-fire fixture and its clean twin.
3. Keep observations and non-draft releases immutable.
4. Select promoted batch IDs before an engine run and bind the exact sorted list into the release input hash.
5. Never make a hard guard client-authoritative or allow eligible rows to pass with zero examined rows.
6. Run `pnpm check`, a local migration, a replay, and the relevant browser review.

Authored grocery configuration lives only in `config/`. After an approved edit run `pnpm tc config generate`;
the files with the same names under `../grocery/` are generated compatibility outputs, not authorities.

Do not cut over a route or retire a legacy subsystem until its milestone window and rollback drill are recorded
in `docs/IMPLEMENTATION-STATUS.md`.

## Default release policy

Implementation work is not complete when it only exists locally. After the required automated, migration,
replay, and browser QA passes with no known bugs, commit the focused change, push it to the configured remote,
deploy it to its intended environment, and run post-deployment API and browser smoke tests in the same task.
Do not leave verified code undeployed by default.

If deployment cannot proceed because credentials, infrastructure, an external dependency, or an explicit
cutover gate is unavailable, report that blocker immediately and preserve a deploy-ready commit. Deploying an
isolated beta or shadow environment does not by itself authorize production traffic cutover or legacy retirement;
those actions still require the applicable milestone evidence above.
