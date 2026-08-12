# Infrastructure hardening status

## Scope and authority

This document records hardening phases H0-H8 on top of the deployed V3 platform. It does not accelerate or
waive V3 evidence gates. `config/schedules.json` owns recurring grocery schedules, `config/agents.json` owns
judgment-agent definitions and prompts live under `agents/`. D1 is the operational ledger; R2 owns backup,
evidence and verified archive objects.

## H0 - baseline truth

- `config/transition-inventory.json` records the evidence counts observed on 2026-08-10 and distinguishes
  retirement blockers from implementation work.
- Every current `SMP *` Windows task is represented in schedule authority. The Facebook reel is explicitly
  adjacent scope and does not block grocery retirement.
- Legacy grocery tasks remain `transition` until their named V3 evidence gates pass.

## H1/H2 - schedule and credential authority

- `tc schedules check` performs bidirectional drift detection across manual-only GitHub workflows, Wrangler
  cron triggers and `grocery/expected-automations.json`. A rogue or missing executor entry fails the local gate.
- GitHub-hosted workflows reject `push`, `pull_request`, and `schedule` triggers. They remain operator-selected
  manual fallbacks; all recurring V3 workloads use America/Chicago Windows tasks.
- The Family Fare paced sweep has an authoritative local three-hour replacement before the legacy task may retire.
- GitHub OIDC trusts exact infrastructure workflows plus ten registered thin agent callers. Agent callers must
  invoke the one approved reusable runner, and both the caller `workflow_ref` and reusable `job_workflow_ref`
  are verified before any capability is granted. The restore workflow can only trigger the deterministic drill.

## H3 - agents as code and plane split

- Ten judgment agents have hashed prompts, semantic execution hashes, agent-specific adversarial evaluation
  corpora, structured input/output contracts, model/fallback/reasoning choices, effective-dated token pricing,
  capabilities, criticality and split routine/reserve budgets.
- An exact execution-hash evaluation must pass before a work item can be claimed. The server owns work-item
  idempotency, leases, fencing, retries, dead letters, severity and chained dispatch; late completions are
  retained as evidence but cannot mutate current state.
- The triage reviewer-to-developer and recipe sourcer-to-auditor chains drain in bounded local cycles.
  Registered agents cannot select their own input contract, credential identity or execution plane.
- Each PC judgment agent has a separate DPAPI-protected HMAC credential. The Worker rereads the active registry
  and applies the same per-agent capability boundary used for GitHub OIDC.
- The triage developer and source-sentinel investigator are pull-request-only, restricted by server and staging
  path allowlists, and run the full repository gate inside an isolated worktree before opening a PR. They
  cannot merge or deploy.

## H4 - immutable content batches

- Recipe-pack content is staged in immutable D1 batches with item hashes, an agent audit and a separate
  deterministic promotion gate.
- The deterministic gate validates duplicate identities, commodity mappings, ingredient coherence and
  provenance. An LLM audit cannot promote content by itself.
- Rejected or promoted batch items cannot be changed or deleted; a correction requires a new batch.
- Recipe publication waves record an immutable pre-wave release snapshot. A failed wave is corrected by
  cloning that snapshot into a new validated release; a superseded release pointer is never reused.
- Login-canary evidence stores only Ghost member IDs/tags and probe timing, rejects email-shaped fields, and
  requires two same-profile probes 9-30 minutes apart.

## H5 - database hardening and recovery

- Migration `0016` is additive. `scripts/check-migrations.mjs` enforces forward expand/contract policy and
  requires a durable restore-proof reference before a future contract migration.
- D1 Time Travel is the primary short-window recovery plane: a daily job records the current bookmark plus
  release/configuration pointers in a content-addressed R2 manifest and verifies the full object after write.
  Blocking SQL export runs weekly, not nightly, and exists for recovery beyond 30 days and independent portability.
- `D1RestoreDrillWorkflow` selects the latest completed R2 SQL backup, creates an explicitly named scratch D1,
  imports it through Cloudflare's D1 import API, compares six core table counts and the current release ID/hash,
  records durable evidence and deletes only the exact scratch UUID.
- Production drill `d1-restore-2026-Q3-a20` passed on 2026-08-10. It restored backup
  `backup_d1-backup-manual-8a1f...`, matched all six backup-derived table counts plus release ID/hash, recovered
  ten oversized release payloads, recorded durable evidence, and removed the scratch D1 and attempt-scoped R2
  staging objects. No restore scratch databases remained after cleanup.
- `/api/v2/replica-canary` is an isolated `first-primary` Sessions API pilot. No public release route is moved
  to replicas until canary evidence proves a benefit without consistency findings.

## H6 - capacity and source contracts

- Daily archival forecasts use database bytes, the configured 10 GiB limit, measured growth, protected release
  references and projected exhaustion rather than a fixed row threshold.
- Archive execution is disarmed below 70% capacity. When armed, a manifest can select only observations older
  than 18 months that are not referenced by a release. Parquet uploads require header/trailer verification,
  SHA-256, R2 reread/size verification and an immutable manifest.
- The Parquet builder pins its runtime in `scripts/requirements-archive.txt`; operators install that file before
  creating an archive object so local and recovery runs use the same Arrow version.
- Source-contract checks are deterministic and run before each server-source ingestion. Failures create durable
  operational alerts; the AI investigator is a read-only second stage.

## H7 - independent browser-capture SLA

- Cloudflare evaluates the Wednesday-through-Tuesday browser cycle independently of the capture PC every hour.
  The check requires all four sources to be full, promoted or superseded, matched, and backed by screenshot,
  session-manifest and projected-raw evidence.
- The SLA begins with the strict 2026-08-12 cycle. It opens a durable digest alert after the Saturday noon
  America/Chicago retry deadline and resolves it automatically after remote truth recovers. A separate monitor
  alert covers failures in the SLA evaluator itself.
- The public status response exposes the current cycle, deadline, ready sources and exact missing conditions,
  so a powered-off PC cannot hide a missed browser week.

## H8 - deployment convergence and browser performance

- `pnpm deploy` now waits for both the direct Workers endpoint and the customer-facing `www.thriftycrew.com`
  route to report the exact deployed Git commit. Cache-busting probes retry for up to 90 seconds, and a stale,
  unavailable or divergent route fails the deployment instead of producing a false-success handoff.
- Every browser batch with a valid, identity-bound session manifest writes one immutable metrics record in the
  same D1 transaction that seals the batch. It records exact term outcomes, retries, chunks, total and p50/p95
  term duration, row yield, accepted observation count and first-party taxonomy coverage.
- `/api/v2/status` exposes the latest aggregate per browser source without evidence payloads. Operators can read
  recent history with `tc capture metrics [limit]`; only engine/operator identities can access batch/session IDs.

## Remaining calendar proof

V3 legacy retirement still depends on the live evidence counters in `IMPLEMENTATION-STATUS.md`. Hardening code
may deploy while those counters accrue, but no transition executor is retired early.

## H9 - unified control plane and bounded state

- Migration `0026` gives PC jobs, agent cycles and Cloudflare Workflows one D1 lease authority with monotonic
  fencing tokens. Scheduled clients carry the acquired fence on every later mutation; current requests renew
  it and stale holders are rejected.
- `pnpm deploy` performs an authenticated drain preflight. Active jobs, D1 exports, restore drills or maintenance
  block a Worker replacement rather than being reset by it.
- Configuration activation now requires a content-addressed, read-after-write verified R2 archive. This bounds
  future recovery dependence on repeated normalized D1 copies without prematurely deleting retained history.
- New configurations reuse content-addressed rule definitions, and the daily lifecycle keeps only the active
  and immediate published rollback rule sets materialized after full-object rehydration verification.
- Capacity planning uses robust recent growth and projected exhaustion in addition to 70%/90% usage thresholds.
  Projected exhaustion within 180 days arms the archive plan; within 30 days is critical.
- Transition retirement is evidence-gated and tombstoned in D1. A later authority sync cannot resurrect a
  retired executor. The current eight transition executors remain because their live gates are not complete.
- The daily cross-plane proof ties configuration, publication, price/recipe accuracy, browser capture, backup,
  execution fencing and capacity into one durable recovery signal.

## H10 - streaming capture transport and event pipeline

- Local capture authority moved from scattered queue, planner, lane and session JSON files into one SQLite WAL
  journal. JSON and NDJSON remain bounded, hash-bound recovery evidence rather than mutable control state.
- Aldi, Fareway, Walmart and Sam's adapters emit the same append-only discovery/verification protocol. The
  persistent at-logon controller owns the two-store concurrency ceiling, store leases, queue wakeups and bounded
  logs. A single-instance per-user supervisor restarts it with bounded backoff after crashes without requiring
  administrator rights, eliminating repeated scheduled process startup as the coordination mechanism.
- Browser evidence is split into bounded immutable product shards and uploaded straight to the evidence bucket.
  The PC never receives an R2 credential: the Worker issues a 15-minute URL bound to one object, identity,
  content type, MD5, SHA-256 metadata and expected byte length, then independently finalizes R2 truth into D1.
- Seal is the handoff boundary. Cloudflare Workflow validates, runs the authored matcher and aisle second
  opinion against the configuration ID/hash pinned at seal, promotes only the exact passed match run, and records
  each stage. Configuration compaction cannot remove a ruleset held by an incomplete pipeline. Cron redispatches transiently failed incomplete
  pipelines, so PC uptime is no longer part of validation, matching or promotion correctness.
- Direct evidence upload uses immutable renewable attempts. A healthy attempt is idempotently reused; expiry or
  rejection creates a new object key. Cloudflare marks stale attempts and deletes only exact R2 keys that have
  remained terminal for one hour and are absent from `evidence_objects`, with a bounded 25-object pass.
